//! Identity inspection keeps the exact selected room behind source admission.
use super::*;
use rooms_application::content::session::workspace;

/// The one coordinate a room identity read takes: the seat the session holds
/// in that room. A seat exists however the member came in, by link, by
/// invitation, or by a listed name, so every member can ask which room they
/// stand in.
pub(super) fn coordinate(args: &[Argument]) -> Result<custody::Coordinate> {
	let [value] = args else {
		return Err(refuse("room identity takes one exact seat coordinate"));
	};
	let coordinate =
		custody::Coordinate::decode(text(value)?).map_err(|_| refuse("invalid room identity coordinate"))?;
	if coordinate.role != custody::Role::RoomSeat {
		return Err(refuse("room identity requires a room seat"));
	}
	Ok(coordinate)
}
pub(super) fn selection(args: &[Argument], intent: &workspace::Intent) -> Result<custody::Coordinate> {
	let selected = coordinate(args)?;
	if !intent.conversations.as_slice().iter().any(|row| matches!(row,
		workspace::Conversation::Room(room) if room.seat.is_some_and(|key| key.slot() == selected.key.slot() && key.generation() == selected.key.generation())
	)) { return Err(refuse("the exact room seat is no longer selected")); }
	Ok(selected)
}
/// One facade over the seat answers both identities: the manager's, and the
/// room's public digest a steward governs.
pub(super) fn invoke(call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
	let record = records::decode(input)?;
	let coordinate = selection(input.args, &record.intent)?;
	let field = record
		.custody
		.get(coordinate)
		.ok_or_else(|| refuse("room identity custody is absent"))?;
	let target = records::reference(&field).resolve(call, input)?;
	let methods = [
		ReadMethod {
			verb: rooms_application::room::authority::MANAGED_IDENTITY,
			results: &[],
		},
		ReadMethod {
			verb: rooms_application::room::authority::ROOM_IDENTITY,
			results: &[],
		},
	];
	call.disclose_reads_copying(&target, &[ReadInterface { methods: &methods }], 0)
		.map(Argument::Reference)
}
