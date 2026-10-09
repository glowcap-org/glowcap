//! A signaling route discloses only the exact registered name's methods.
use super::{MetadataRecord, records, refuse, text};
use glowcap::{
	Argument, Result,
	loam::{Call, Delivery, Invocation, ReadInterface, ReadMethod, ReferenceRequest, Requirement},
};
use rooms_application::{
	content::{
		permissions::Permission,
		session::{custody, workspace::SignalingSelection},
	},
	signaling as policy,
};

fn selection(input: Invocation<'_>) -> Result<SignalingSelection> {
	let [value] = input.args else {
		return Err(refuse("signaling takes one exact registration selection"));
	};
	let encoded = text(value)?;
	if encoded.len() > 1024 * 6 + 768 {
		return Err(refuse("signaling selection exceeds its profile"));
	}
	serde_json::from_str(encoded).map_err(|_| refuse("invalid signaling selection"))
}
/// Intent evidence for private supervision carries no signaling custody.
pub(super) fn selected_requirement(input: Invocation<'_>) -> Result<Requirement> {
	selection(input)?;
	Requirement::new(&[Permission::ObserveWorkspace.key()], &[])
}
pub(super) fn selected(input: Invocation<'_>) -> Result<Argument> {
	Ok(selection(input)?.matches(&records::metadata(input)?.intent).into())
}
fn locations(record: &MetadataRecord, input: Invocation<'_>) -> Result<[records::Location; 2]> {
	let selected = selection(input)?;
	if !selected.matches(&record.intent) {
		return Err(refuse("signaling registration or source was replaced"));
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
		return Err(refuse("signaling directory custody is absent"));
	}
	let [source, target] = [
		coordinate(
			custody::Role::SessionAccess,
			selected.source.slot(),
			selected.source.generation(),
		),
		coordinate(
			custody::Role::DirectoryName,
			selected.name.slot(),
			selected.name.generation(),
		),
	]
	.map(|coordinate| {
		record
			.custody
			.get(coordinate)
			.map(|held| records::location(&held))
			.ok_or_else(|| refuse("signaling custody is absent"))
	});
	Ok([source?, target?])
}
pub(super) fn requirement(input: Invocation<'_>) -> Result<Requirement> {
	selection(input)?;
	if input.delivery == Delivery::Forwarding {
		locations(&records::metadata(input)?, input)?;
	}
	Requirement::new(&[Permission::InteractWorkspace.key()], &[])
}
pub(super) fn references(input: Invocation<'_>, record: &MetadataRecord) -> Result<Vec<ReferenceRequest>> {
	let locations = locations(record, input)?;
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
					.ok_or_else(|| refuse("invalid signaling custody page"))?,
				field: location.field,
			})
		})
		.collect()
}
pub(super) fn invoke(call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
	let [source, target] = locations(&records::metadata(input)?, input)?;
	let mut held = |location: records::Location| {
		let page = input
			.graph
			.and_then(|pages| pages.get(location.page.checked_sub(1)?))
			.ok_or_else(|| refuse("invalid signaling custody page"))?;
		call.page_reference(page, location.field)
	};
	let source = held(source)?;
	let target = held(target)?;
	if source != call.source()? {
		return Err(refuse("original signaling source capability required"));
	}
	let methods = [
		policy::OFFER_INBOX,
		policy::OFFER,
		policy::ANSWER,
		policy::CANDIDATE,
		policy::DONE,
		policy::CHECK,
	]
	.map(|verb| ReadMethod { verb, results: &[] });
	// Source arguments and six method declarations are charged by the shared
	// continuation budget. Neither directory owner authority nor name leave
	// and voucher methods are disclosed through this ephemeral route.
	call.disclose_reads_copying(&target, &[ReadInterface { methods: &methods }], 0)
		.map(Argument::Reference)
}
