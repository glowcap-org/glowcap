//! Callback admission checks the current row and exact initiating endpoint in
//! one shared call. It restores only that source and the installed callback.
use super::{MetadataRecord, records, refuse, text};
use glowcap::{
	Argument, Result,
	loam::{Call, Invocation, ReferenceRequest},
};
use rooms_application::content::session::{custody, workspace::InboxSelection};

pub(super) fn selection(input: Invocation<'_>) -> Result<InboxSelection> {
	let [encoded, Argument::Reference(_)] = input.args else {
		return Err(refuse("inbox admission takes one selection and its actual callback"));
	};
	let encoded = text(encoded)?;
	// Two bounded display IDs may each require six JSON bytes per UTF-16
	// unit. The fixed allowance covers tags and typed custody coordinates.
	if encoded.len() > 2 * 1024 * 6 + 1024 {
		return Err(refuse("inbox selection exceeds its profile"));
	}
	serde_json::from_str(encoded).map_err(|_| refuse("invalid inbox selection"))
}
fn locations(record: &MetadataRecord, selection: &InboxSelection) -> Result<[records::Location; 2]> {
	if !selection.matches(&record.intent) {
		return Err(refuse("inbox or initiating source was retired"));
	}
	let key = selection.source();
	let field = record
		.custody
		.get(custody::Coordinate {
			role: custody::Role::SessionAccess,
			key: custody::FieldKey::new(key.slot(), key.generation()),
		})
		.ok_or_else(|| refuse("inbox source custody is absent"))?;
	let inbox = record
		.custody
		.get(selection.coordinate())
		.ok_or_else(|| refuse("inbox custody is absent"))?;
	Ok([records::location(&field), records::location(&inbox)])
}
pub(super) fn references(input: Invocation<'_>, record: &MetadataRecord) -> Result<Vec<ReferenceRequest>> {
	locations(record, &selection(input)?)?
		.into_iter()
		.map(|location| {
			Ok(ReferenceRequest::RestorePage {
				page: location
					.page
					.checked_sub(1)
					.ok_or_else(|| refuse("invalid inbox custody page"))?,
				field: location.field,
			})
		})
		.collect()
}
pub(super) fn invoke(call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
	let record = records::metadata(input)?;
	let [source, inbox] = locations(&record, &selection(input)?)?;
	let page = |location: records::Location| {
		input
			.graph
			.and_then(|pages| pages.get(location.page.checked_sub(1)?))
			.ok_or_else(|| refuse("invalid inbox custody page"))
	};
	if call.page_reference(page(source)?, source.field)? != call.source()? {
		return Err(refuse("original inbox source capability required"));
	}
	let Argument::Reference(actual) = &input.args[1] else {
		unreachable!("selection checked callback shape")
	};
	if call.page_reference(page(inbox)?, inbox.field)? != *actual {
		return Err(refuse("installed callback capability required"));
	}
	Ok(Argument::Boolean(record.intent.keep_history))
}
