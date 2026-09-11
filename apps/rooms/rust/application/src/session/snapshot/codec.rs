use super::*;
use crate::session::fields::{present, version};
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct AccessWire {
	#[serde(deserialize_with = "version")]
	version: u8,
	rights: Access,
	workspace_adoption: Adoption,
	grants: List<GrantView, 32>,
	#[serde(default, deserialize_with = "present", skip_serializing_if = "Option::is_none")]
	suspended_note: Option<DocumentText>,
}
fn json<T: serde::de::DeserializeOwned>(raw: &str, max: usize) -> Result<T, Refusal> {
	if raw.encode_utf16().take(max + 1).count() > max {
		return Err(Refusal::Text);
	}
	serde_json::from_str(raw).map_err(|_| Refusal::Json)
}
fn text<A: SnapshotArgument>(arg: &A) -> Result<&str, Refusal> {
	arg.text().ok_or(Refusal::Shape)
}
fn field<A: SnapshotArgument, const N: usize>(arg: &A) -> Result<Text<N>, Refusal> {
	let text = text(arg)?;
	if text.encode_utf16().take(N + 1).count() > N {
		return Err(Refusal::Text);
	}
	Ok(Text(text.into()))
}
fn list<A: SnapshotArgument, T, const N: usize>(
	arg: &A,
	read: impl Fn(A::Item<'_>) -> Result<T, Refusal>,
) -> Result<List<T, N>, Refusal> {
	let values = arg.list().ok_or(Refusal::Shape)?;
	if values.len() > N {
		return Err(Refusal::Shape);
	}
	values.map(read).collect::<Result<Vec<_>, _>>().map(List)
}
fn tuple<A: SnapshotArgument, const N: usize>(arg: &A) -> Result<[A::Item<'_>; N], Refusal> {
	let mut values = arg.list().ok_or(Refusal::Shape)?;
	if values.len() != N {
		return Err(Refusal::Shape);
	}
	Ok(core::array::from_fn(|_| values.next().expect("exact length checked")))
}
// Inspect only the schema's bounded nesting before retaining data. A malformed
// nested tree is refused without recursive walking or capability cloning.
fn wire_bytes<A: SnapshotArgument>(arg: &A, depth: usize) -> Result<usize, Refusal> {
	if let Some(text) = arg.text() {
		return Ok(text.len());
	}
	if let Some(values) = arg.list() {
		if depth == 0 || values.len() > MAX_ISSUES {
			return Err(Refusal::Shape);
		}
		let mut n = 0usize;
		for value in values {
			n = n.checked_add(wire_bytes(&value, depth - 1)?).ok_or(Refusal::Budget)?;
			if n > MAX_TEXT_BYTES {
				return Err(Refusal::Budget);
			}
		}
		return Ok(n);
	}
	Ok(0)
}
pub(super) fn read<A: SnapshotArgument>(args: &[A], routes: &impl Routes) -> Result<Snapshot, Refusal> {
	if args.len() != super::WIRE_FIELDS {
		return Err(Refusal::Shape);
	}
	let mut bytes = 0usize;
	for arg in args {
		bytes = bytes.checked_add(wire_bytes(arg, 2)?).ok_or(Refusal::Budget)?;
	}
	if bytes > MAX_TEXT_BYTES {
		return Err(Refusal::Budget);
	}
	let revision = args[0]
		.integer()
		.and_then(|n| u64::try_from(n).ok())
		.and_then(SafeInteger::new)
		.ok_or(Refusal::Shape)?;
	let access: AccessWire = json(text(&args[10])?, 640 * 1024)?;
	let snapshot = Snapshot {
		revision,
		checkpoint: Rc::new(Checkpoint::decode(text(&args[1])?, routes).map_err(|_| Refusal::Checkpoint)?),
		pending_effects: list(&args[2], |v| field(&v))?,
		issues: list(&args[3], |v| {
			let [a, b] = tuple(&v)?;
			Ok((field(&a)?, field(&b)?))
		})?,
		connected_directories: list(&args[4], |v| field(&v))?,
		pending_effect_details: list(&args[5], |v| {
			let [a, b, c, d] = tuple(&v)?;
			Ok((
				field(&a)?,
				field(&b)?,
				field(&c)?,
				EffectPhase::parse(text(&d)?).ok_or(Refusal::Shape)?,
			))
		})?,
		member_locator: if args[6].is_null() {
			Nullable::Null
		} else {
			Nullable::Value(field(&args[6])?)
		},
		room_views: json(text(&args[7])?, 512 * 1024)?,
		archive_shares: json(text(&args[8])?, 128 * 1024)?,
		directory_views: json(text(&args[9])?, 2 * 1024 * 1024)?,
		access: access.rights,
		workspace_adoption: access.workspace_adoption,
		grants: access.grants,
		suspended_note: access.suspended_note,
		handed_rooms: json(text(&args[11])?, 128 * 1024)?,
	};
	snapshot.validate()?;
	Ok(snapshot)
}

fn render<T: Serialize + ?Sized>(value: &T) -> Result<String, Refusal> {
	serde_json::to_string(value).map_err(|_| Refusal::Json)
}
// serde_json's no-std surface exposes owned serialization only. Stage one
// bounded row, check its size, then copy it once into the retained JSON list.
// This intentional staging bounds overflow work to one row instead of building
// every live row before dropping the oversized list.
fn live<T: Serialize>(values: impl IntoIterator<Item = T>, max_units: usize) -> Result<Option<String>, Refusal> {
	let mut output = String::from("[");
	let mut units = 1;
	let mut first = true;
	for value in values {
		let row = render(&value)?;
		let separator = usize::from(!first);
		units += separator + row.encode_utf16().count();
		if output.len() + separator + row.len() + 1 > MAX_TEXT_BYTES || units + 1 > max_units {
			return Ok(None);
		}
		if !first {
			output.push(',');
		}
		first = false;
		output.push_str(&row);
	}
	output.push(']');
	Ok(Some(output))
}
fn byte_len(text: &DocumentText) -> usize {
	core::char::decode_utf16(text.utf16())
		.map(|c| c.unwrap_or(core::char::REPLACEMENT_CHARACTER).len_utf8())
		.sum()
}
fn out<B: BuildArguments>(text: &DocumentText) -> B::Value {
	B::text(text.utf8_lossy().into_owned())
}
type Projection<'a> = (Access, &'a DocumentText, &'a [(Field, Field)]);

pub(super) fn encode<B: BuildArguments>(
	s: &Snapshot,
	projection: Option<Projection<'_>>,
) -> Result<Vec<B::Value>, Refusal> {
	s.validate()?;
	let rights = projection.map_or(s.access, |p| p.0);
	let observing = projection.is_none() || rights != Access::None;
	let admin = projection.is_none() || rights == Access::Admin;
	let interacting = projection.is_none() || matches!(rights, Access::Admin | Access::Interact);
	let pending = if observing { &s.pending_effects.0[..] } else { &[] };
	let connected = if observing { &s.connected_directories.0[..] } else { &[] };
	let mut details = if admin { &s.pending_effect_details.0[..] } else { &[] };
	let member = if observing { s.member_locator.as_ref() } else { None };
	let own_issues = if observing { &s.issues.0[..] } else { &[] };
	let extras = projection.map_or(&[][..], |p| p.2);
	if own_issues.len() + extras.len() > MAX_ISSUES {
		return Err(Refusal::Shape);
	}
	let issues = || own_issues.iter().chain(extras);
	let note = match projection {
		Some((_, note, _)) if note.utf16().next().is_some() => Some(note),
		Some(_) => None,
		None => s.suspended_note.as_ref(),
	};
	#[derive(Serialize)]
	#[serde(rename_all = "camelCase")]
	struct AccessView<'a> {
		version: u8,
		rights: Access,
		workspace_adoption: Adoption,
		grants: &'a [GrantView],
		#[serde(skip_serializing_if = "Option::is_none")]
		suspended_note: Option<&'a DocumentText>,
	}
	// Unbounded protocol strings are bounded by their enclosing JSON fields.
	// Check before serializing a locally constructed view, too.
	if note.is_some_and(|n| n.utf16().take(640 * 1024 + 1).count() > 640 * 1024) {
		return Err(Refusal::Text);
	}
	let checkpoint = s
		.checkpoint
		.encode_for(projection.map_or(Access::Admin, |p| p.0))
		.map_err(|_| Refusal::Checkpoint)?;
	let access = render(&AccessView {
		version: 1,
		rights,
		workspace_adoption: if observing {
			s.workspace_adoption
		} else {
			Adoption::Closed
		},
		grants: if admin { &s.grants.0 } else { &[] },
		suspended_note: note,
	})?;
	if checkpoint.encode_utf16().count() > super::super::checkpoint::MAX_CHECKPOINT_UNITS
		|| access.encode_utf16().count() > 640 * 1024
	{
		return Err(Refusal::Text);
	}
	let rooms = live(
		s.room_views
			.0
			.iter()
			.take(if observing { usize::MAX } else { 0 })
			.map(|v| views::VisibleRoom(v, interacting)),
		512 * 1024,
	)?;
	let shares = if observing
		&& s.archive_shares.0.iter().any(|v| {
			v.scope_conversation
				.as_ref()
				.is_some_and(|t| t.utf16().take(128 * 1024 + 1).count() > 128 * 1024)
		}) {
		None
	} else {
		live(
			s.archive_shares.0.iter().take(if observing { usize::MAX } else { 0 }),
			128 * 1024,
		)?
	};
	let directories = live(
		s.directory_views.0.iter().take(if observing { usize::MAX } else { 0 }),
		2 * 1024 * 1024,
	)?;
	let handed = live(
		s.handed_rooms.0.iter().take(if observing { usize::MAX } else { 0 }),
		128 * 1024,
	)?;
	let live_overflow = [&rooms, &shares, &directories, &handed].iter().any(|v| v.is_none());
	let mut json = [
		checkpoint,
		rooms.unwrap_or_else(|| "[]".into()),
		shares.unwrap_or_else(|| "[]".into()),
		directories.unwrap_or_else(|| "[]".into()),
		access,
		handed.unwrap_or_else(|| "[]".into()),
	];
	let fixed =
		pending.iter().chain(connected).map(|v| byte_len(&v.0)).sum::<usize>() + member.map_or(0, |v| byte_len(&v.0));
	let issue_bytes = |count: usize| {
		issues()
			.take(count)
			.map(|(a, b)| byte_len(&a.0) + byte_len(&b.0))
			.sum::<usize>()
	};
	let detail_bytes = |rows: &[(Field, Field, Field, EffectPhase)]| {
		rows.iter()
			.map(|(a, b, c, d)| byte_len(&a.0) + byte_len(&b.0) + byte_len(&c.0) + d.as_str().len())
			.sum::<usize>()
	};
	let mut retained = own_issues.len() + extras.len();
	let mut overflow = false;
	const OVERFLOW: [&str; 2] = [
		"snapshot-overflow",
		"the Rooms session snapshot exceeds its complete wire-text budget",
	];
	let overflow_bytes = OVERFLOW.iter().map(|s| s.len()).sum::<usize>();
	if live_overflow
		|| fixed + issue_bytes(retained) + detail_bytes(details) + json.iter().map(String::len).sum::<usize>()
			> MAX_TEXT_BYTES
	{
		overflow = true;
		retained = retained.min(MAX_ISSUES - 1);
		for i in [1, 2, 3, 5] {
			json[i] = "[]".into();
		}
		if fixed
			+ issue_bytes(retained)
			+ overflow_bytes
			+ detail_bytes(details)
			+ json.iter().map(String::len).sum::<usize>()
			> MAX_TEXT_BYTES
		{
			retained = 0;
			details = &[];
			if fixed + overflow_bytes + json.iter().map(String::len).sum::<usize>() > MAX_TEXT_BYTES {
				return Err(Refusal::Budget);
			}
		}
	}
	let mut issue_values: Vec<_> = issues()
		.take(retained)
		.map(|(a, b)| B::list(alloc::vec![out::<B>(&a.0), out::<B>(&b.0)]))
		.collect();
	if overflow {
		issue_values.push(B::list(OVERFLOW.into_iter().map(|s| B::text(s.into())).collect()));
	}
	let [checkpoint, rooms, shares, directories, access, handed] = json;
	Ok(alloc::vec![
		B::integer(s.revision.get()),
		B::text(checkpoint),
		B::list(pending.iter().map(|v| out::<B>(&v.0)).collect()),
		B::list(issue_values),
		B::list(connected.iter().map(|v| out::<B>(&v.0)).collect()),
		B::list(
			details
				.iter()
				.map(|(a, b, c, d)| B::list(alloc::vec![
					out::<B>(&a.0),
					out::<B>(&b.0),
					out::<B>(&c.0),
					B::text(d.as_str().into())
				]))
				.collect()
		),
		member.map_or_else(B::null, |v| out::<B>(&v.0)),
		B::text(rooms),
		B::text(shares),
		B::text(directories),
		B::text(access),
		B::text(handed),
	])
}

#[cfg(test)]
mod tests {
	#[test]
	fn overflow_stops_before_serializing_the_remaining_live_rows() {
		let visited = core::cell::Cell::new(0);
		let rows = (0..256).map(|_| {
			visited.set(visited.get() + 1);
			"row"
		});
		assert!(super::live(rows, 10).unwrap().is_none());
		assert_eq!(
			visited.get(),
			2,
			"only the fitting row and first overflowing row are visited"
		);
	}
}
