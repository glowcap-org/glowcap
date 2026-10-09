//! Identity inspection keeps the exact selected room behind source admission.
use super::*;
use rooms_application::content::session::workspace;

pub(super) fn coordinate(args: &[Argument]) -> Result<custody::Coordinate> {
	let [value] = args else {
		return Err(refuse("room identity takes one exact access coordinate"));
	};
	let coordinate =
		custody::Coordinate::decode(text(value)?).map_err(|_| refuse("invalid room identity coordinate"))?;
	if coordinate.role != custody::Role::RoomAccess {
		return Err(refuse("room identity requires room access"));
	}
	Ok(coordinate)
}
pub(super) fn selection(args: &[Argument], intent: &workspace::Intent) -> Result<custody::Coordinate> {
	let selected = coordinate(args)?;
	if !intent.conversations.as_slice().iter().any(|row| matches!(row,
		workspace::Conversation::Room(room) if room.access.is_some_and(|key| key.slot() == selected.key.slot() && key.generation() == selected.key.generation())
	)) { return Err(refuse("the exact room access is no longer selected")); }
	Ok(selected)
}
pub(super) fn invoke(call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
	let record = records::decode(input)?;
	let coordinate = selection(input.args, &record.intent)?;
	let field = record
		.custody
		.get(coordinate)
		.ok_or_else(|| refuse("room identity custody is absent"))?;
	let target = records::reference(&field).resolve(call, input)?;
	let methods = [ReadMethod {
		verb: rooms_application::room::authority::MANAGED_IDENTITY,
		results: &[],
	}];
	call.disclose_reads_copying(&target, &[ReadInterface { methods: &methods }], 0)
		.map(Argument::Reference)
}
pub(super) fn publication_identity(call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
	let record = records::metadata(input)?;
	let selected = selection(input.args, &record.intent)?;
	let field = record
		.custody
		.get(selected)
		.ok_or_else(|| refuse("room publication custody is absent"))?;
	let location = records::location(&field);
	let page = input
		.graph
		.and_then(|pages| pages.get(location.page.checked_sub(1)?))
		.ok_or_else(|| refuse("invalid room publication page"))?;
	let uri = call
		.page_saved_uri(page, location.field)?
		.ok_or_else(|| refuse("the exact room has no publication recipe"))?;
	let sturdy = glowcap::parse_sturdyref(uri, glowcap::CaptpVersion::V1_0)?;
	let token = core::str::from_utf8(&sturdy.swissnum).map_err(|_| refuse("invalid room publication token"))?;
	let identity = rooms_application::room::authority::room_identity(token)
		.map_err(|_| refuse("invalid room publication identity"))?;
	Ok(identity.into())
}
