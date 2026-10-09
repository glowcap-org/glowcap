//! Operator inventory rows render into the bounded wire-facing view schema.
use super::*;
use crate::{fields::List, room::ListArgument};
use alloc::vec::Vec;

pub(crate) fn tuple<A: ListArgument, const N: usize>(value: &A) -> Result<[A; N], Refusal> {
	if value.list_len() != Some(N) {
		return Err(Refusal::Shape);
	}
	let fields: [Option<A>; N] = core::array::from_fn(|i| value.at(i));
	if fields.iter().any(Option::is_none) {
		return Err(Refusal::Shape);
	}
	Ok(fields.map(Option::unwrap))
}
pub(crate) fn text<const N: usize, const NONEMPTY: bool>(
	value: &impl ListArgument,
) -> Result<Text<N, NONEMPTY>, Refusal> {
	let text = value
		.text()
		.filter(|s| Text::<N, NONEMPTY>::accepts_utf16(s.encode_utf16()))
		.ok_or(Refusal::Text)?;
	Ok(Text::new(text.into()).expect("checked text"))
}
pub(crate) fn number<const POSITIVE: bool>(value: &impl ListArgument) -> Result<SafeInteger<POSITIVE>, Refusal> {
	value
		.integer()
		.and_then(|n| u64::try_from(n).ok())
		.and_then(SafeInteger::new)
		.ok_or(Refusal::Number)
}
pub(crate) fn boolean(value: &impl ListArgument) -> Result<bool, Refusal> {
	value.boolean().ok_or(Refusal::Shape)
}
fn nullable(value: &impl ListArgument) -> Result<Nullable<SafeInteger>, Refusal> {
	if value.is_null() {
		Ok(Nullable::Null)
	} else {
		number(value).map(Nullable::Value)
	}
}
fn revision(value: &impl ListArgument) -> Result<Revision, Refusal> {
	Revision::new(
		value
			.integer()
			.and_then(|n| u128::try_from(n).ok())
			.ok_or(Refusal::Number)?,
	)
}
fn visibility(value: &impl ListArgument) -> Result<Visibility, Refusal> {
	match value.text() {
		Some("listed") => Ok(Visibility::Listed),
		Some("private") => Ok(Visibility::Private),
		_ => Err(Refusal::Kind),
	}
}
pub(crate) fn list<A: ListArgument, T, const N: usize>(
	value: &A,
	read: impl Fn(&A) -> Result<T, Refusal>,
) -> Result<List<Object<T>, N>, Refusal> {
	let len = value.list_len().filter(|n| *n <= N).ok_or(Refusal::Budget)?;
	let mut out = Vec::with_capacity(len);
	for i in 0..len {
		out.push(Object(read(&value.at(i).ok_or(Refusal::Shape)?)?));
	}
	Ok(List::new(out).expect("bounded operator page"))
}
pub fn read_stewardship<A: ListArgument>(value: &A) -> Result<Stewardship, Refusal> {
	let [name, label, visible, generation, issued, steward] = tuple(value)?;
	let row = Stewardship {
		name: text(&name)?,
		label: text(&label)?,
		visibility: visibility(&visible)?,
		generation: number(&generation)?,
		issued: boolean(&issued)?,
		steward: if steward.is_null() {
			Nullable::Null
		} else {
			Nullable::Value(text(&steward)?)
		},
	};
	row.validate()?;
	Ok(row)
}
fn room<A: ListArgument>(value: &A) -> Result<Room, Refusal> {
	let [id, kind, name, origin, proof, retained, members, more] = tuple(value)?;
	// Direct tuples historically require a room id; the JSON view permits an
	// empty id. Keep that wire distinction explicit rather than normalizing it.
	if id.text().is_none_or(str::is_empty) {
		return Err(Refusal::Text);
	}
	Ok(Room {
		id: text(&id)?,
		kind: match kind.text() {
			Some("local") => RoomKind::Local,
			Some("private") => RoomKind::Private,
			Some("peered") => RoomKind::Peered,
			Some("pending-peered") => RoomKind::PendingPeered,
			Some("irc") => RoomKind::Irc,
			_ => return Err(Refusal::Kind),
		},
		name: text(&name)?,
		origin: text(&origin)?,
		proof: match proof.text() {
			Some("local") => Proof::Local,
			Some("authenticated") => Proof::Authenticated,
			Some("session") => Proof::Session,
			Some("bridge") => Proof::Bridge,
			_ => return Err(Refusal::Kind),
		},
		retained_capabilities: nullable(&retained)?,
		members: list(&members, |value| {
			let [nick, session, state] = tuple(value)?;
			Ok(Member {
				nick: text(&nick)?,
				session_id: text(&session)?,
				state: text(&state)?,
			})
		})?,
		members_more: boolean(&more)?,
	})
}
fn rows<A: ListArgument>(category: Category, value: &A) -> Result<PageRows, Refusal> {
	Ok(match category {
		Category::Stewardships => PageRows::Stewardships(list(value, read_stewardship)?),
		Category::Links => PageRows::Links(list(value, |value| {
			let [name, label, visible] = tuple(value)?;
			Ok(Link {
				name: text(&name)?,
				label: text(&label)?,
				visibility: visibility(&visible)?,
			})
		})?),
		Category::Registrations => PageRows::Registrations(list(value, |value| {
			let [nick, session, you] = tuple(value)?;
			Ok(Registration {
				nick: text(&nick)?,
				session_id: text(&session)?,
				you: boolean(&you)?,
			})
		})?),
		Category::Sessions => PageRows::Sessions(list(value, |value| {
			let [id, transport, nick, you] = tuple(value)?;
			Ok(Session {
				id: text(&id)?,
				transport: text(&transport)?,
				nick: text(&nick)?,
				you: boolean(&you)?,
			})
		})?),
		Category::Rooms => PageRows::Rooms(list(value, room)?),
		Category::References => PageRows::References(list(value, |value| {
			let [id, kind, owner, room, member, detail] = tuple(value)?;
			Ok(Reference {
				id: text(&id)?,
				kind: kind.text().and_then(ReferenceKind::parse).ok_or(Refusal::Kind)?,
				owner: text(&owner)?,
				room: text(&room)?,
				member: text(&member)?,
				detail: text(&detail)?,
			})
		})?),
		Category::Trouble => PageRows::Trouble(list(value, |value| {
			let [source, reason, count] = tuple(value)?;
			if source
				.text()
				.is_none_or(|s| s.len() > crate::server::operations::journal::MAX_SOURCE_BYTES)
				|| reason
					.text()
					.is_none_or(|s| s.len() > crate::server::operations::journal::MAX_REASON_BYTES)
			{
				return Err(Refusal::Text);
			}
			Ok(Trouble {
				source: text(&source)?,
				reason: text(&reason)?,
				count: number(&count)?,
			})
		})?),
	})
}

// Scan borrowed input before copying display text. Each list is bounded by its
// wire role below; this aggregate allowance also bounds hostile nested values.
pub(crate) fn budget(value: &impl ListArgument, units: &mut usize, depth: u8) -> Result<(), Refusal> {
	*units = units.checked_sub(1).ok_or(Refusal::Budget)?;
	if let Some(text) = value.text() {
		*units = units
			.checked_sub(text.encode_utf16().take(*units + 1).count())
			.ok_or(Refusal::Budget)?;
	} else if let Some(len) = value.list_len() {
		if depth == 0 || len > *units {
			return Err(Refusal::Budget);
		}
		for i in 0..len {
			budget(&value.at(i).ok_or(Refusal::Shape)?, units, depth - 1)?;
		}
	} else if value.contains_capability() {
		return Err(Refusal::Shape);
	}
	Ok(())
}
pub fn read_page<A: ListArgument>(category: Category, value: &A) -> Result<Page, Refusal> {
	let mut remaining = MAX_JSON_UNITS;
	budget(value, &mut remaining, 6)?;
	let [rev, next, raw, total] = tuple(value)?;
	Ok(Page {
		revision: revision(&rev)?,
		next: nullable(&next)?,
		total: number(&total)?,
		rows: rows(category, &raw)?,
	})
}
pub fn read_retire<A: ListArgument>(value: &A) -> Result<RetireBatch, Refusal> {
	let [retired, remaining, refused] = tuple(value)?;
	Ok(RetireBatch {
		retired: number(&retired)?,
		remaining: number(&remaining)?,
		refused: text(&refused)?,
	})
}
pub fn read_snapshot<A: ListArgument>(value: &A) -> Result<Snapshot, Refusal> {
	let mut remaining = MAX_JSON_UNITS;
	// Whole inventory adds the category envelope above the room member tuples.
	budget(value, &mut remaining, 7)?;
	let [rev, pages] = tuple(value)?;
	if pages.list_len() != Some(7) {
		return Err(Refusal::Shape);
	}
	let empty = || List::new(Vec::new()).expect("empty page");
	let mut snapshot = Snapshot {
		revision: revision(&rev)?,
		stewardships: empty(),
		links: List::new(Vec::new()).unwrap(),
		registrations: List::new(Vec::new()).unwrap(),
		sessions: List::new(Vec::new()).unwrap(),
		rooms: List::new(Vec::new()).unwrap(),
		references: List::new(Vec::new()).unwrap(),
		trouble: List::new(Vec::new()).unwrap(),
		next: Object(Categories {
			stewardships: Nullable::Null,
			links: Nullable::Null,
			registrations: Nullable::Null,
			sessions: Nullable::Null,
			rooms: Nullable::Null,
			references: Nullable::Null,
			trouble: Nullable::Null,
		}),
		totals: Object(Categories {
			stewardships: SafeInteger::new(0).unwrap(),
			links: SafeInteger::new(0).unwrap(),
			registrations: SafeInteger::new(0).unwrap(),
			sessions: SafeInteger::new(0).unwrap(),
			rooms: SafeInteger::new(0).unwrap(),
			references: SafeInteger::new(0).unwrap(),
			trouble: SafeInteger::new(0).unwrap(),
		}),
	};
	let mut seen = [false; 7];
	for i in 0..7 {
		let [category, next, raw, total] = tuple(&pages.at(i).ok_or(Refusal::Shape)?)?;
		let category = category.text().and_then(Category::parse).ok_or(Refusal::Kind)?;
		if core::mem::replace(&mut seen[category as usize], true) {
			return Err(Refusal::Relation);
		}
		*snapshot.next.0.get_mut(category) = nullable(&next)?;
		*snapshot.totals.0.get_mut(category) = number(&total)?;
		match rows(category, &raw)? {
			PageRows::Stewardships(r) => snapshot.stewardships = r,
			PageRows::Links(r) => snapshot.links = r,
			PageRows::Registrations(r) => snapshot.registrations = r,
			PageRows::Sessions(r) => snapshot.sessions = r,
			PageRows::Rooms(r) => snapshot.rooms = r,
			PageRows::References(r) => snapshot.references = r,
			PageRows::Trouble(r) => snapshot.trouble = r,
		}
	}
	Ok(snapshot)
}
