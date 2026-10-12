//! Ephemeral typing retains the selected conversation's exact source and target.
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
		locations(&records::metadata(input)?, input)?;
	}
	Requirement::new(&[Permission::InteractWorkspace.key()], &[])
}
fn locations(record: &MetadataRecord, input: Invocation<'_>) -> Result<[records::Location; 2]> {
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
		workspace::Conversation::Direct(row)
			if !row.closed
				&& target.role == custody::Role::DirectAccess
				&& row.access.is_some_and(|access| {
					access.slot() == target.key.slot() && access.generation() == target.key.generation()
				}) =>
		{
			row.source
		}
		_ => return Err(refuse("typing target has been replaced or retired")),
	}
	.ok_or_else(|| refuse("typing conversation has no initiating source"))?;
	if source.slot() != expected_source.key.slot() || source.generation() != expected_source.key.generation() {
		return Err(refuse("typing initiating source has been replaced"));
	}
	let locate = |coordinate| {
		record
			.custody
			.get(coordinate)
			.map(|held| records::location(&held))
			.ok_or_else(|| refuse("typing custody is absent"))
	};
	Ok([
		locate(custody::Coordinate {
			role: custody::Role::SessionAccess,
			key: custody::FieldKey::new(source.slot(), source.generation()),
		})?,
		locate(target)?,
	])
}
pub(super) fn references(input: Invocation<'_>, record: &MetadataRecord) -> Result<Vec<ReferenceRequest>> {
	let locations = locations(record, input)?;
	// Fresh acquisition validates and restores only the exact source/target.
	// Forwarding keeps those held references and rechecks current scalar intent.
	if input.delivery == Delivery::Forwarding {
		return Ok(Vec::new());
	}
	locations
		.into_iter()
		.map(|location| {
			Ok(ReferenceRequest::RestorePage {
				page: location
					.page
					.checked_sub(1)
					.ok_or_else(|| refuse("invalid typing custody page"))?,
				field: location.field,
			})
		})
		.collect()
}
/// The shared read scope copies three bounded source arguments and one method
/// declaration, retaining the exact source and target until facade retirement.
/// Its existing continuation count/byte budget owns this cost. A raw upstream
/// sender would let typing survive source revocation and selection replacement.
pub(super) fn invoke(call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
	let record = records::metadata(input)?;
	let [source, target] = locations(&record, input)?;
	let mut held = |location: records::Location| {
		let page = input
			.graph
			.and_then(|pages| pages.get(location.page.checked_sub(1)?))
			.ok_or_else(|| refuse("invalid typing custody page"))?;
		call.page_reference(page, location.field)
	};
	let source = held(source)?;
	let target = held(target)?;
	if source != call.source()? {
		return Err(refuse("original conversation source capability required"));
	}
	let methods = [ReadMethod {
		verb: rooms_application::protocol_data::TYPING,
		results: &[],
	}];
	call.disclose_reads_copying(&target, &[ReadInterface { methods: &methods }], 0)
		.map(Argument::Reference)
}
