//! The admitted callback retires exact canonical custody after upstream revocation.
//! Recipe inspection never restores the publication that has just been withdrawn.
use super::*;
use rooms_application::room::stewardship::Kind;

fn coordinate<K>(role: custody::Role, key: custody::FieldKey<K>) -> custody::Coordinate {
	custody::Coordinate {
		role,
		key: custody::FieldKey::new(key.slot(), key.generation()),
	}
}
fn callback(input: Invocation<'_>) -> Result<Invocation<'_>> {
	if input.args.len() != 5 {
		return Err(refuse(
			"authority retirement takes owner, callback selection, callback, role and token",
		));
	}
	Ok(Invocation {
		args: &input.args[1..3],
		..input
	})
}
fn kind(input: Invocation<'_>) -> Result<Kind> {
	match text(&input.args[3])? {
		"room" => Ok(Kind::Room),
		"steward" => Ok(Kind::Steward),
		"manager" => Ok(Kind::Manager),
		_ => Err(refuse("unknown retired room authority")),
	}
}
fn selection(input: Invocation<'_>, record: &MetadataRecord) -> Result<Option<custody::Coordinate>> {
	let workspace::InboxSelection::Room { id, .. } = inbox::selection(callback(input)?)? else {
		return Err(refuse("room authority retirement requires a room callback"));
	};
	let room = record
		.intent
		.conversations
		.as_slice()
		.iter()
		.find_map(|row| match row {
			workspace::Conversation::Room(row) if row.id == id => Some(row),
			_ => None,
		})
		.ok_or_else(|| refuse("the original room is no longer held"))?;
	Ok(match kind(input)? {
		Kind::Room => room.access.map(|key| coordinate(custody::Role::RoomAccess, key)),
		Kind::Steward => room.moderator.map(|key| coordinate(custody::Role::RoomAccess, key)),
		Kind::Manager => room.control.map(|key| coordinate(custody::Role::RoomControl, key)),
	})
}
pub(super) fn requirement(input: Invocation<'_>, root: &Ref) -> Result<Requirement> {
	super::super::retained::authorize(input, root)?;
	inbox::selection(callback(input)?)?;
	kind(input)?;
	let token = text(&input.args[4])?;
	if token.is_empty() || token.len() > 128 {
		return Err(refuse("invalid retired publication token"));
	}
	Requirement::new(&[Permission::ObserveWorkspace.key()], &[])
}
pub(super) fn references(input: Invocation<'_>, record: &MetadataRecord) -> Result<Vec<ReferenceRequest>> {
	let mut references = inbox::references(callback(input)?, record)?;
	if let Some(coordinate) = selection(input, record)? {
		let field = record
			.custody
			.get(coordinate)
			.ok_or_else(|| refuse("room authority custody is absent"))?;
		let location = records::location(&field);
		references.push(ReferenceRequest::InspectPageUri {
			page: location
				.page
				.checked_sub(1)
				.ok_or_else(|| refuse("invalid room authority page"))?,
			field: location.field,
		});
	}
	Ok(references)
}
pub(super) fn invoke(call: &mut Call<'_>, input: Invocation<'_>, root: &Ref) -> Result<Argument> {
	requirement(input, root)?;
	inbox::invoke(call, callback(input)?)?;
	let metadata = records::metadata(input)?;
	let Some(coordinate) = selection(input, &metadata)? else {
		return Ok(Argument::Void);
	};
	let field = metadata
		.custody
		.get(coordinate)
		.ok_or_else(|| refuse("room authority custody is absent"))?;
	let location = records::location(&field);
	let page = input
		.graph
		.and_then(|pages| pages.get(location.page.checked_sub(1)?))
		.ok_or_else(|| refuse("invalid room authority page"))?;
	let Some(uri) = call.page_saved_uri(page, location.field)? else {
		return Ok(Argument::Void);
	};
	let token = rooms_glowcap::routes::authority_token(uri).map_err(|_| refuse("invalid room authority recipe"))?;
	if token.as_deref() != Some(text(&input.args[4])?) {
		return Ok(Argument::Void);
	}
	let mut record = records::decode(input)?;
	if coordinate.role == custody::Role::RoomControl {
		local::retire_room_control(
			&mut record.intent,
			&mut record.custody,
			custody::FieldKey::new(coordinate.key.slot(), coordinate.key.generation()),
		);
	} else {
		local::retire_authority(
			&mut record.intent,
			&mut record.custody,
			custody::FieldKey::new(coordinate.key.slot(), coordinate.key.generation()),
		);
	}
	records::replace(call, input, &mut record)?;
	Ok(Argument::Void)
}
