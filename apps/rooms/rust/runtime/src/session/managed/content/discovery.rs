//! Viewer reads retain their invoking grant and exact upstream target.
//! Descriptive row IDs select held custody. They cannot substitute for it.
use super::{MetadataRecord, records, refuse, text};
use glowcap::{
	Argument, Result,
	loam::{Call, Delivery, Invocation, ReadInterface, ReadMethod, ReferenceRequest, Requirement},
};
use rooms_application::{
	content::permissions::Permission,
	content::session::{custody, workspace::DiscoverySelection},
	directory,
};

fn selection(input: Invocation<'_>) -> Result<DiscoverySelection> {
	let [value] = input.args else {
		return Err(refuse("discovery admission takes one exact selection"));
	};
	let encoded = text(value)?;
	if encoded.len() > 1024 * 6 + 512 {
		return Err(refuse("discovery selection exceeds its profile"));
	}
	serde_json::from_str(encoded).map_err(|_| refuse("invalid discovery selection"))
}
fn admission_location(input: Invocation<'_>, record: &MetadataRecord) -> Result<records::Location> {
	let selected = selection(input)?;
	if !selected.matches(&record.intent) {
		return Err(refuse("discovery directory or initiating source was retired"));
	}
	let coordinate = |role, slot, generation| custody::Coordinate {
		role,
		key: custody::FieldKey::new(slot, generation),
	};
	if record
		.custody
		.get(coordinate(
			custody::Role::DirectoryAccess,
			selected.access.slot(),
			selected.access.generation(),
		))
		.is_none()
	{
		return Err(refuse("discovery directory custody is absent"));
	}
	record
		.custody
		.get(coordinate(
			custody::Role::SessionAccess,
			selected.source.slot(),
			selected.source.generation(),
		))
		.map(|held| records::location(&held))
		.ok_or_else(|| refuse("discovery source custody is absent"))
}
pub(super) fn admission_requirement(input: Invocation<'_>) -> Result<Requirement> {
	selection(input)?;
	Requirement::new(&[Permission::ObserveWorkspace.key()], &[])
}
/// Scalar intent for worker retirement. ObserveWorkspace already discloses
/// these coordinates through snapshot. This query carries no custody and
/// cannot authorize callbacks or substitute another initiating source.
pub(super) fn selected(input: Invocation<'_>) -> Result<Argument> {
	Ok(selection(input)?.matches(&records::metadata(input)?.intent).into())
}
pub(super) fn admission_references(input: Invocation<'_>, record: &MetadataRecord) -> Result<Vec<ReferenceRequest>> {
	let location = admission_location(input, record)?;
	Ok(vec![ReferenceRequest::RestorePage {
		page: location
			.page
			.checked_sub(1)
			.ok_or_else(|| refuse("invalid discovery source page"))?,
		field: location.field,
	}])
}
pub(super) fn admit(call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
	let location = admission_location(input, &records::metadata(input)?)?;
	let page = input
		.graph
		.and_then(|pages| pages.get(location.page.checked_sub(1)?))
		.ok_or_else(|| refuse("invalid discovery source page"))?;
	if call.page_reference(page, location.field)? != call.source()? {
		return Err(refuse("original discovery source capability required"));
	}
	Ok(Argument::Void)
}

pub(super) fn requirement(input: Invocation<'_>) -> Result<Requirement> {
	let [id] = input.args else {
		return Err(refuse("directory-reader takes one directory row identity"));
	};
	if !rooms_application::fields::Text::<1024, true>::accepts_utf16(text(id)?.encode_utf16()) {
		return Err(refuse("invalid directory row identity"));
	}
	Requirement::new(&[Permission::ObserveWorkspace.key()], &[])
}
fn location(record: &MetadataRecord, input: Invocation<'_>) -> Result<records::Location> {
	let id = text(&input.args[0])?;
	let row = record
		.intent
		.directories
		.as_slice()
		.iter()
		.find(|row| row.id.text().as_str() == Some(id))
		.ok_or_else(|| refuse("directory is not selected in this workspace"))?;
	let held = record
		.custody
		.get(custody::Coordinate {
			role: custody::Role::DirectoryAccess,
			key: custody::FieldKey::new(row.access.slot(), row.access.generation()),
		})
		.ok_or_else(|| refuse("directory custody is absent"))?;
	Ok(records::location(&held))
}
pub(super) fn references(input: Invocation<'_>, record: &MetadataRecord) -> Result<Vec<ReferenceRequest>> {
	// The facade already holds its exact source and target. Workspace edits
	// cannot redirect it or require restoring unrelated/new directory custody.
	if input.delivery == Delivery::Forwarding {
		return Ok(Vec::new());
	}
	let location = location(record, input)?;
	Ok(vec![ReferenceRequest::RestorePage {
		page: location
			.page
			.checked_sub(1)
			.ok_or_else(|| refuse("invalid directory custody page"))?,
		field: location.field,
	}])
}
pub(super) fn invoke(call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
	let record = records::metadata(input)?;
	let location = location(&record, input)?;
	let page = input
		.graph
		.and_then(|pages| pages.get(location.page.checked_sub(1)?))
		.ok_or_else(|| refuse("invalid directory custody page"))?;
	let target = call.page_reference(page, location.field)?;
	// ObserveWorkspace admits this viewer's read. The scope below retains that
	// exact invoking grant and rechecks it on every forwarded call. Directory
	// workers separately authenticate their initiating source in check-discovery.
	let methods = [
		directory::LIST,
		directory::NAMED,
		directory::creation::LOCATION,
		directory::registration::MEMBER,
	]
	.map(|verb| ReadMethod { verb, results: &[] });
	call.disclose_reads_copying(&target, &[ReadInterface { methods: &methods }], 0)
		.map(Argument::Reference)
}
