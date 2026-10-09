//! A sender event requires the exact private source saved with its line.
use super::*;

pub(super) fn selection(input: Invocation<'_>) -> Result<custody::FieldKey<custody::Line>> {
	let [encoded] = input.args else {
		return Err(refuse("outgoing admission takes one line coordinate"));
	};
	let encoded = text(encoded)?;
	if encoded.len() > 128 {
		return Err(refuse("invalid outgoing line coordinate"));
	}
	serde_json::from_str(encoded).map_err(|_| refuse("invalid outgoing line coordinate"))
}
fn source(record: &MetadataRecord, selected: custody::FieldKey<custody::Line>) -> Result<records::Location> {
	let origin = record
		.outgoing
		.as_slice()
		.iter()
		.find(|origin| origin.line == selected)
		.ok_or_else(|| refuse("original outgoing line was retired"))?;
	if !record.intent.conversations.as_slice().iter().any(|row| {
		row.id() == &origin.conversation
			&& row
				.lines()
				.iter()
				.any(|line| line.handle == selected && line.id == origin.id)
	}) {
		return Err(refuse("original outgoing conversation or line was retired"));
	}
	let held = record
		.custody
		.get(custody::Coordinate {
			role: custody::Role::SessionAccess,
			key: custody::FieldKey::new(origin.source.slot(), origin.source.generation()),
		})
		.ok_or_else(|| refuse("original outgoing source was retired"))?;
	Ok(records::location(&held))
}
pub(super) fn references(input: Invocation<'_>, record: &MetadataRecord) -> Result<Vec<ReferenceRequest>> {
	let location = source(record, selection(input)?)?;
	Ok(vec![ReferenceRequest::RestorePage {
		page: location
			.page
			.checked_sub(1)
			.ok_or_else(|| refuse("invalid outgoing source page"))?,
		field: location.field,
	}])
}
pub(super) fn invoke(call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
	let record = records::metadata(input)?;
	let source = source(&record, selection(input)?)?;
	let page = input
		.graph
		.and_then(|pages| pages.get(source.page.checked_sub(1)?))
		.ok_or_else(|| refuse("invalid outgoing source page"))?;
	if call.page_reference(page, source.field)? != call.source()? {
		return Err(refuse("original outgoing source capability required"));
	}
	Ok(Argument::Void)
}
