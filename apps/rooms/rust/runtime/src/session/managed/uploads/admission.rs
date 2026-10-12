//! Restore only selected and unresolved batches. Aliases compare actual authority.
use super::super::{
	State,
	content::{self, MetadataRecord},
	executor::Seat,
	records::{self, Field},
};
use super::*;
use glowcap::loam::{Call, Invocation, ReferenceRequest};
use rooms_application::{
	content::session::{custody::Outcome, effects},
	fields::Text,
};
use rooms_glowcap::client::{Deadline, Tasks};
use std::{num::NonZeroU64, rc::Rc};

fn restore(location: records::Location) -> Result<ReferenceRequest> {
	Ok(ReferenceRequest::RestorePage {
		page: location
			.page
			.checked_sub(1)
			.ok_or_else(|| refuse("invalid upload custody page"))?,
		field: location.field,
	})
}
pub(in crate::session::managed) fn references(
	input: Invocation<'_>,
	record: &MetadataRecord,
) -> Result<Vec<ReferenceRequest>> {
	let request = Request::read(input.verb, input.args)?;
	if input.delivery == loam::Delivery::Forwarding {
		return Ok(Vec::new());
	}
	if let Some(receipt) = record
		.effects
		.as_slice()
		.iter()
		.find(|row| row.operation.text().as_str() == Some(request.intent.operation.as_str()))
	{
		let mut requests = vec![restore(receipt.source.reference)?];
		requests.extend(
			receipt
				.targets
				.as_slice()
				.iter()
				.skip(request.intent.target_count())
				.map(|field| restore(records::location(&field.borrowed())))
				.collect::<Result<Vec<_>>>()?,
		);
		return Ok(requests);
	}
	let mut requests = request
		.intent
		.coordinates(&record.intent)
		.map_err(|error| refuse(&error.to_string()))?
		.into_iter()
		.map(|coordinate| {
			let target = record
				.custody
				.get(coordinate)
				.ok_or_else(|| refuse("upload target custody is absent"))?;
			restore(records::location(&target))
		})
		.collect::<Result<Vec<_>>>()?;
	if let Kind::Refile(_) = request.intent.upload {
		let target = request
			.intent
			.coordinates(&record.intent)
			.map_err(|error| refuse(&error.to_string()))?[1];
		requests.extend(super::super::outgoing::references(record, target)?);
	}
	for receipt in record.effects.as_slice() {
		if matches!(receipt.outcome, Outcome::Unresolved)
			&& receipt
				.canonical_intent
				.text()
				.as_str()
				.is_some_and(|text| text.starts_with('{'))
		{
			let target = receipt
				.targets
				.as_slice()
				.first()
				.ok_or_else(|| refuse("upload receipt has no files facet"))?;
			if target.borrowed().coordinate().role != custody::Role::RoomFiles {
				continue;
			}
			requests.push(restore(records::location(&target.borrowed()))?);
		}
	}
	requests.extend(request.sources.into_iter().map(ReferenceRequest::SaveLive));
	Ok(requests)
}
pub(in crate::session::managed) fn admit<P: Tasks + Deadline + Clone + 'static>(
	owner: &Rc<State<P>>,
	call: &mut Call<'_>,
	input: Invocation<'_>,
) -> Result<Argument> {
	let request = Request::read(input.verb, input.args)?;
	let canonical = request.intent.canonical().map_err(|error| refuse(&error.to_string()))?;
	let id = Text::new(request.intent.operation.clone().into()).ok_or_else(|| refuse("invalid upload operation"))?;
	let intent = Text::new(canonical.clone().into()).ok_or_else(|| refuse("upload intent exceeds receipt capacity"))?;
	let metadata = records::metadata(input)?;
	let source = call.source()?;
	if let Some(receipt) = metadata.effects.as_slice().iter().find(|row| row.operation == id) {
		content::receipts::authenticate(call, input, &metadata, &id, &source)?;
		let receipt = effects::inspect(&metadata.effects, &id, &receipt.source.reference, &intent)
			.map_err(|_| refuse("original upload intent required"))?
			.ok_or_else(|| refuse("original upload receipt is absent"))?;
		let original = &receipt.targets.as_slice()[request.intent.target_count()..];
		if original.len() != request.sources.len() {
			return Err(refuse("original upload sources required"));
		}
		for (field, incoming) in original.iter().zip(&request.sources) {
			let held = records::location(&field.borrowed());
			let page = input
				.graph
				.and_then(|pages| pages.get(held.page.checked_sub(1)?))
				.ok_or_else(|| refuse("invalid source blob page"))?;
			if call.page_reference(page, held.field)? != *incoming {
				return Err(refuse("original source blob required"));
			}
		}
		return Ok(content::receipts::status(
			receipt,
			owner.running(&request.intent.operation),
		));
	}
	if input.content_revision != request.intent.base {
		return Err(refuse("workspace revision changed"));
	}
	let coordinates = request
		.intent
		.coordinates(&metadata.intent)
		.map_err(|error| refuse(&error.to_string()))?;
	let mut targets = coordinates
		.iter()
		.map(|coordinate| {
			let held = metadata
				.custody
				.get(*coordinate)
				.ok_or_else(|| refuse("upload target custody is absent"))?;
			let held = records::location(&held);
			let page = input
				.graph
				.and_then(|pages| pages.get(held.page.checked_sub(1)?))
				.ok_or_else(|| refuse("invalid upload target page"))?;
			call.page_reference(page, held.field)
		})
		.collect::<Result<Vec<_>>>()?;
	let direct = coordinates[0].role == custody::Role::DirectAccess;
	for receipt in metadata.effects.as_slice().iter().filter(|_| !direct) {
		if receipt
			.targets
			.as_slice()
			.first()
			.is_none_or(|field| field.borrowed().coordinate().role != custody::Role::RoomFiles)
		{
			continue;
		}
		if !matches!(receipt.outcome, Outcome::Unresolved)
			|| !receipt
				.canonical_intent
				.text()
				.as_str()
				.is_some_and(|text| text.starts_with('{'))
		{
			continue;
		}
		let id = receipt
			.operation
			.text()
			.as_str()
			.ok_or_else(|| refuse("invalid upload receipt"))?;
		if owner
			.jobs
			.borrow()
			.get(id)
			.and_then(|job| job.batch_released.as_ref())
			.is_some_and(|released| released.get())
		{
			continue;
		}
		let held = records::location(
			&receipt
				.targets
				.as_slice()
				.first()
				.ok_or_else(|| refuse("invalid upload receipt"))?
				.borrowed(),
		);
		let page = input
			.graph
			.and_then(|pages| pages.get(held.page.checked_sub(1)?))
			.ok_or_else(|| refuse("invalid batch custody page"))?;
		if call.page_reference(page, held.field)? == targets[0] {
			return Err(refuse("original files facet has an unresolved upload batch"));
		}
	}
	let withdrawing = matches!(request.intent.upload, Kind::Refile(_))
		&& request.intent.caption.is_empty()
		&& request.intent.keep.is_empty()
		&& request.sources.is_empty();
	if !withdrawing {
		owner.admission.borrow_mut().upload(
			call,
			request.sources.len(),
			&request.intent.caption,
			owner.platform.monotonic_millis(),
		)?;
	}
	let seat = Seat::reserve(owner, &request.intent.operation)?;
	targets.extend(request.sources.iter().cloned());
	let (reservation, pending) = call.reserve_continuation_copying(&targets)?;
	let mut retained = coordinates
		.into_iter()
		.zip(&targets)
		.map(|(coordinate, target)| records::restored(coordinate, Field::Held(target.clone())))
		.collect::<Vec<_>>();
	for (index, source) in request.sources.into_iter().enumerate() {
		retained.push(records::restored(
			custody::Coordinate {
				role: custody::Role::SourceBlob,
				key: custody::FieldKey::new(
					NonZeroU64::new(index as u64 + 1).ok_or_else(|| refuse("invalid upload source slot"))?,
					NonZeroU64::MIN,
				),
			},
			Field::Held(source),
		));
	}
	let source = reservation.source()?;
	let mut record = records::decode(input)?;
	let outgoing = if direct {
		let files = request
			.intent
			.files
			.as_slice()
			.iter()
			.zip(&targets[request.intent.target_count()..])
			.map(|(description, blob)| {
				Ok(attachment::Attachment {
					description: description.file().map_err(|error| refuse(&error.to_string()))?,
					blob: blob.clone(),
				})
			})
			.collect::<Result<Vec<_>>>()?;
		match request.intent.upload {
			Kind::Post => Some(
				super::super::outgoing::Capture::post(
					owner,
					&mut record,
					input,
					source.clone(),
					super::super::outgoing::Post {
						operation: &request.intent.operation,
						conversation: &request.intent.conversation,
						text: &request.intent.caption,
						previews: rooms_application::open_graph::Selection::decode(
							&request.intent.caption,
							&request.intent.previews,
						)
						.map_err(|_| refuse("invalid outgoing previews"))?,
						files: &files,
					},
				)?
				.upload(),
			),
			Kind::Refile(_) => {
				let target = request
					.intent
					.coordinates(&record.intent)
					.map_err(|error| refuse(&error.to_string()))?[1];
				let change = if request.intent.caption.is_empty() && request.intent.keep.is_empty() && files.is_empty()
				{
					rooms_application::room::message::ChangeKind::Withdrawn
				} else {
					rooms_application::room::message::ChangeKind::Refiled
				};
				super::super::outgoing::Capture::change(
					owner,
					&mut record,
					call,
					input,
					target,
					super::super::outgoing::Edit {
						text: &request.intent.caption,
						change,
						keep: Some(request.intent.keep.as_slice()),
						submitted: &files,
					},
				)?
				.map(super::super::outgoing::Capture::upload)
			}
		}
	} else {
		None
	};
	let mut admitted = content::receipt(input, id, intent, source.clone(), retained)?;
	admitted.outgoing = outgoing.as_ref().map(super::super::outgoing::Capture::reservation);
	content::reserve(owner, &mut record, admitted)?;
	records::replace_effects(call, input, &record)?;
	seat.start_upload(pending, source, canonical, request.intent, direct, outgoing)?;
	Ok("pending".into())
}
