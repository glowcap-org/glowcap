//! The workspace snapshot, and on request the address each held directory was
//! dialed through. Addresses derive from saved recipes inside the one answer.
use super::{MetadataRecord, records, refuse};
use glowcap::{
	Argument, Result,
	loam::{Call, Invocation, ReferenceRequest},
};
use rooms_application::content::session::{custody, workspace::Directory};

/// `snapshot` answers `[revision, intent]`. `addressed-snapshot` also answers
/// one address per directory row, in row order, so a page can show and share
/// the route each directory was dialed through, while internal readers pay no
/// recipe inspection. Neither takes an argument.
fn addressed(input: Invocation<'_>) -> Result<bool> {
	if !input.args.is_empty() {
		return Err(refuse(&format!("{} takes no argument", input.verb)));
	}
	Ok(input.verb == "addressed-snapshot")
}
fn page_index(location: &records::Location) -> Result<usize> {
	location
		.page
		.checked_sub(1)
		.ok_or_else(|| refuse("invalid directory recipe page"))
}
pub(super) fn requirement(input: Invocation<'_>) -> Result<()> {
	addressed(input).map(drop)
}
fn location(record: &MetadataRecord, row: &Directory) -> Option<records::Location> {
	let coordinate = custody::Coordinate::new(custody::Role::DirectoryAccess, row.access);
	record.custody.get(coordinate).map(|field| records::location(&field))
}
/// Inspection reads each saved recipe row without restoring or dialing it, so
/// the answer stays an ObserveWorkspace read. An addressed answer pays one
/// recipe row read per held directory inside the same call, overlapped by the
/// store's read-ahead. A row the store cannot read fails the answer like any
/// other storage read. A row without custody has no address, and
/// `Intent::validate` keeps that case out of committed records.
pub(super) fn references(input: Invocation<'_>, record: &MetadataRecord) -> Result<Vec<ReferenceRequest>> {
	if !addressed(input)? {
		return Ok(Vec::new());
	}
	record
		.intent
		.directories
		.as_slice()
		.iter()
		.filter_map(|row| location(record, row))
		.map(|location| {
			Ok(ReferenceRequest::InspectPageUri {
				page: page_index(&location)?,
				field: location.field,
			})
		})
		.collect()
}
pub(super) fn invoke(call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
	let addressed = addressed(input)?;
	let record = records::metadata(input)?;
	let revision = i64::try_from(input.content_revision).map_err(|_| refuse("workspace revision exhausted"))?;
	let intent = serde_json::to_string(&record.intent).map_err(|_| refuse("invalid workspace"))?;
	let mut reply = vec![Argument::Integer(revision), Argument::String(intent)];
	if addressed {
		let addresses = record
			.intent
			.directories
			.as_slice()
			.iter()
			.map(|row| Ok(address(call, input, &record, row)?.map_or(Argument::Void, Argument::String)))
			.collect::<Result<Vec<_>>>()?;
		reply.push(Argument::List(addresses));
	}
	Ok(Argument::List(reply))
}
/// The dialed route without the swiss number, or None for a row whose saved
/// link is local, live, or not a capability. The pages `references` asked for
/// are already read, so a recipe this cannot decode is a damaged record, and
/// the answer refuses the way every other storage read does.
fn address(call: &Call<'_>, input: Invocation<'_>, record: &MetadataRecord, row: &Directory) -> Result<Option<String>> {
	let Some(location) = location(record, row) else {
		return Ok(None);
	};
	let page = input
		.graph
		.and_then(|graph| graph.get(page_index(&location).ok()?))
		.ok_or_else(|| refuse("directory recipe page was not read"))?;
	let Some(uri) = call.page_saved_uri(page, location.field)? else {
		return Ok(None);
	};
	let address = rooms_glowcap::routes::Address::capability(uri).map_err(|error| *error)?;
	Ok(address.map(|address| address.address))
}
