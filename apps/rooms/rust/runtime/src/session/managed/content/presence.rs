//! Ephemeral typing retains the selected conversation's exact target. The
//! caller names the conversation's initiating source too, so a sender opened
//! before that source was replaced stops. Any access whose rights admit
//! typing may open one, as any such access may say a line there, and the
//! sender is re-admitted through the caller's own access on every send, so
//! that access's pause or revocation stops it.
use super::{MetadataRecord, records, refuse, text};
use glowcap::{
	Argument, Result,
	loam::{Call, Delivery, Invocation, ReadInterface, ReadMethod, ReferenceRequest, Requirement},
};
use rooms_application::content::{
	permissions::Permission,
	session::{custody, workspace},
};

fn request(input: Invocation<'_>) -> Result<(&str, custody::Coordinate, custody::Coordinate)> {
	let [id, coordinate, source] = input.args else {
		return Err(refuse(
			"typing-sender takes a conversation and exact target/source coordinates",
		));
	};
	let id = text(id)?;
	if !rooms_application::fields::Text::<1024, true>::accepts_utf16(id.encode_utf16()) {
		return Err(refuse("invalid conversation identity"));
	}
	let coordinate =
		custody::Coordinate::decode(text(coordinate)?).map_err(|_| refuse("invalid typing target coordinate"))?;
	if !matches!(coordinate.role, custody::Role::RoomSeat | custody::Role::DirectAccess) {
		return Err(refuse("typing requires a held room seat or direct route"));
	}
	let source = custody::Coordinate::decode(text(source)?).map_err(|_| refuse("invalid typing source coordinate"))?;
	if source.role != custody::Role::SessionAccess {
		return Err(refuse("typing requires the initiating session source"));
	}
	Ok((id, coordinate, source))
}
pub(super) fn requirement(input: Invocation<'_>) -> Result<Requirement> {
	request(input)?;
	if input.delivery == Delivery::Forwarding {
		location(&records::metadata(input)?, input)?;
	}
	Requirement::new(&[Permission::InteractWorkspace.key()], &[])
}
fn location(record: &MetadataRecord, input: Invocation<'_>) -> Result<records::Location> {
	let (id, target, expected_source) = request(input)?;
	let row = record
		.intent
		.conversations
		.as_slice()
		.iter()
		.find(|row| row.id().text().as_str() == Some(id))
		.ok_or_else(|| refuse("typing conversation is no longer selected"))?;
	let source = match row {
		workspace::Conversation::Room(row)
			if row.requests_membership()
				&& target.role == custody::Role::RoomSeat
				&& row.seat.is_some_and(|seat| {
					seat.slot() == target.key.slot() && seat.generation() == target.key.generation()
				}) =>
		{
			row.source
		}
		workspace::Conversation::Direct(row) if row.installs(target) => row.source,
		_ => return Err(refuse("typing target has been replaced or retired")),
	}
	.ok_or_else(|| refuse("typing conversation has no initiating source"))?;
	if source.slot() != expected_source.key.slot() || source.generation() != expected_source.key.generation() {
		return Err(refuse("typing initiating source has been replaced"));
	}
	record
		.custody
		.get(target)
		.map(|held| records::location(&held))
		.ok_or_else(|| refuse("typing custody is absent"))
}
pub(super) fn references(input: Invocation<'_>, record: &MetadataRecord) -> Result<Vec<ReferenceRequest>> {
	let location = location(record, input)?;
	// Fresh acquisition validates and restores only the exact target.
	// Forwarding keeps that held reference and rechecks current scalar intent.
	if input.delivery == Delivery::Forwarding {
		return Ok(Vec::new());
	}
	Ok(vec![ReferenceRequest::RestorePage {
		page: location
			.page
			.checked_sub(1)
			.ok_or_else(|| refuse("invalid typing custody page"))?,
		field: location.field,
	}])
}
/// The shared read scope copies three bounded source arguments and one method
/// declaration, retaining the exact target until facade retirement. Its
/// existing continuation count/byte budget owns this cost. The scope is the
/// caller's own access, so each send is admitted through it again. A raw
/// upstream sender would let typing survive that access's revocation and a
/// replaced selection.
pub(super) fn invoke(call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
	let record = records::metadata(input)?;
	let target = location(&record, input)?;
	let page = input
		.graph
		.and_then(|pages| pages.get(target.page.checked_sub(1)?))
		.ok_or_else(|| refuse("invalid typing custody page"))?;
	let target = call.page_reference(page, target.field)?;
	let methods = [ReadMethod {
		verb: rooms_application::protocol_data::TYPING,
		results: &[],
	}];
	call.disclose_reads_copying(&target, &[ReadInterface { methods: &methods }], 0)
		.map(Argument::Reference)
}
