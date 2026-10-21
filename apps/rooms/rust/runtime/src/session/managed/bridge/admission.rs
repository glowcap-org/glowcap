//! Bridge admission retains public intent, exact seat and independent origins.
use super::*;
use crate::session::managed::{
	allocation::Allocator,
	content,
	executor::Seat,
	records::{self, Field},
};
use glowcap::loam;
use glowcap::{
	Ref,
	loam::{Call, Invocation, ReferenceRequest},
};
use rooms_application::{
	bridge::Answers,
	content::session::{
		bridge::{self, Request},
		custody::{self, Coordinate, Held},
		effects,
	},
	fields::{SafeInteger, Text},
};
use std::num::NonZeroU64;

pub(in crate::session::managed) fn request(args: &[Argument]) -> Result<(Request, Answers)> {
	let [id, canonical, secrets] = args else {
		return Err(loam::refusal(
			"bridge submission requires id, public intent and private answers",
		));
	};
	let request = Request::read(content::text(canonical)?).map_err(|_| loam::refusal("invalid bridge intent"))?;
	if request.operation.text().as_str() != Some(content::text(id)?)
		|| !request.bridge.validate()
		|| request
			.canonical()
			.map_err(|_| loam::refusal("invalid bridge intent"))?
			!= content::text(canonical)?
	{
		return Err(loam::refusal("invalid canonical bridge intent"));
	}
	let secrets =
		Answers::decode(content::text(secrets)?).map_err(|_| loam::refusal("invalid private bridge answers"))?;
	if secrets.iter().any(|(id, _)| !request.bridge.declaration.is_secret(id))
		|| (request.reapply.is_some() && !secrets.is_empty())
		|| (request.reapply.is_none() && secrets.is_empty() != request.credentials.is_none())
	{
		return Err(loam::refusal("private answers differ from the declared secret fields"));
	}
	Ok((request, secrets))
}
fn coordinate<K>(role: custody::Role, key: custody::FieldKey<K>) -> Coordinate {
	Coordinate {
		role,
		key: custody::FieldKey::new(key.slot(), key.generation()),
	}
}
fn restore(location: records::Location) -> Result<ReferenceRequest> {
	Ok(ReferenceRequest::RestorePage {
		page: location
			.page
			.checked_sub(1)
			.ok_or_else(|| loam::refusal("invalid bridge custody page"))?,
		field: location.field,
	})
}
pub(in crate::session::managed) fn references(
	input: Invocation<'_>,
	record: &content::MetadataRecord,
) -> Result<Vec<ReferenceRequest>> {
	if input.verb == "bridge-reapplication" {
		let [_, _, room] = input.args else {
			return Err(loam::refusal("bridge reapplication takes operation, base and room"));
		};
		let witness = record
			.bridges
			.as_slice()
			.iter()
			.rev()
			.find(|witness| witness.room.text().as_str() == room.as_str())
			.ok_or_else(|| loam::refusal("original bridge witness is absent"))?;
		return Ok(vec![restore(
			record
				.custody
				.session_access(witness.source)
				.ok_or_else(|| loam::refusal("original bridge source custody is absent"))?
				.reference,
		)?]);
	}
	let (request, _) = request(input.args)?;
	if let Some(receipt) = record
		.effects
		.as_slice()
		.iter()
		.find(|receipt| receipt.operation == request.operation)
	{
		return Ok(vec![restore(receipt.source.reference)?]);
	}
	if !request.selected(&record.intent) {
		return Err(loam::refusal("original bridge seat or continuing access changed"));
	}
	let mut keys = vec![coordinate(custody::Role::RoomSeat, request.seat)];
	keys.extend(request.access);
	if let Some(id) = request.reapply {
		let witness = record
			.bridges
			.as_slice()
			.iter()
			.find(|witness| witness.id == id)
			.ok_or_else(|| loam::refusal("original bridge witness is absent"))?;
		keys.push(coordinate(custody::Role::SessionAccess, witness.source));
		keys.extend(witness.access);
	}
	keys.into_iter()
		.map(|key| {
			let held = record
				.custody
				.get(key)
				.ok_or_else(|| loam::refusal("bridge custody is absent"))?;
			restore(records::location(&held))
		})
		.collect()
}
pub(in crate::session::managed) fn reapplication(call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
	let [operation, base, room] = input.args else {
		return Err(loam::refusal("bridge reapplication takes operation, base and room"));
	};
	let operation =
		Text::new(content::text(operation)?.into()).ok_or_else(|| loam::refusal("invalid bridge operation"))?;
	let base = base
		.as_i64()
		.and_then(|base| u64::try_from(base).ok())
		.and_then(SafeInteger::new)
		.ok_or_else(|| loam::refusal("invalid bridge revision"))?;
	if base.get() != input.content_revision {
		return Err(loam::refusal(rooms_application::failure::stale_workspace()));
	}
	let record = records::decode(input)?;
	let witness = record
		.bridges
		.as_slice()
		.iter()
		.rev()
		.find(|witness| witness.room.text().as_str() == room.as_str())
		.ok_or_else(|| loam::refusal("original bridge witness is absent"))?;
	let source = record
		.custody
		.session_access(witness.source)
		.ok_or_else(|| loam::refusal("original bridge source custody is absent"))?
		.reference
		.resolve(call, input)?;
	if source != call.source()? || !witness.applied || witness.access.is_none() {
		return Err(loam::refusal(
			"successful original bridge source and continuing access required",
		));
	}
	let selected = record
		.intent
		.conversations
		.as_slice()
		.iter()
		.find_map(|row| match row {
			rooms_application::content::session::workspace::Conversation::Room(row) if row.id == witness.room => {
				Some(row)
			}
			_ => None,
		})
		.ok_or_else(|| loam::refusal("original bridge room is absent"))?;
	if bridge::selection(selected) != witness.selection {
		return Err(loam::refusal("original bridge access selection changed"));
	}
	let request = Request {
		bridge: witness.intent.clone(),
		operation,
		base,
		room: witness.room.clone(),
		seat: selected
			.seat
			.ok_or_else(|| loam::refusal("rejoin through original continuing access before reapplication"))?,
		access: witness.selection,
		credentials: witness.credentials.clone(),
		reapply: Some(witness.id),
	};
	request
		.canonical()
		.map(Into::into)
		.map_err(|_| loam::refusal("invalid bridge reapplication"))
}
pub(in crate::session::managed) fn admit<P: Tasks + Deadline + Clone + 'static>(
	owner: &Rc<State<P>>,
	call: &mut Call<'_>,
	input: Invocation<'_>,
) -> Result<Argument> {
	let (request, secrets) = request(input.args)?;
	let canonical = request
		.canonical()
		.map_err(|_| loam::refusal("invalid bridge intent"))?;
	let intent =
		Text::new(canonical.clone().into()).ok_or_else(|| loam::refusal("bridge intent exceeds receipt capacity"))?;
	let metadata = records::metadata(input)?;
	let source = call.source()?;
	if let Some(receipt) = metadata
		.effects
		.as_slice()
		.iter()
		.find(|row| row.operation == request.operation)
	{
		content::receipts::authenticate(call, input, &metadata, &request.operation, &source)?;
		owner.admission.borrow_mut().work(
			call,
			rooms_application::admission::Class::Read,
			None,
			owner.platform.monotonic_millis(),
		)?;
		let receipt = effects::inspect(
			&metadata.effects,
			&request.operation,
			&receipt.source.reference,
			&intent,
		)
		.map_err(|_| loam::refusal("original public bridge intent required"))?
		.ok_or_else(|| loam::refusal("original bridge receipt is absent"))?;
		return Ok(content::receipts::status(
			receipt,
			owner.running(
				request
					.operation
					.text()
					.as_str()
					.ok_or_else(|| loam::refusal("invalid bridge operation"))?,
			),
		));
	}
	if request.base.get() != input.content_revision {
		return Ok("conflict".into());
	}
	if !request.selected(&metadata.intent) {
		return Err(loam::refusal("original bridge seat or continuing access changed"));
	}
	owner.admission.borrow_mut().work(
		call,
		rooms_application::admission::Class::Create,
		None,
		owner.platform.monotonic_millis(),
	)?;
	let credentials = owner
		.credentials
		.borrow()
		.clone()
		.ok_or_else(|| loam::refusal("bridge credential owner is not installed"))?;
	let mut record = records::decode(input)?;
	let coordinates: Vec<_> = std::iter::once(coordinate(custody::Role::RoomSeat, request.seat))
		.chain(request.access)
		.collect();
	let targets = coordinates
		.iter()
		.map(|key| resolve(&record, *key, call, input))
		.collect::<Result<Vec<_>>>()?;
	let id = if let Some(id) = request.reapply {
		let witness = record
			.bridges
			.as_slice()
			.iter()
			.find(|witness| witness.id == id)
			.ok_or_else(|| loam::refusal("original bridge witness is absent"))?;
		if !witness.applied
			|| witness.access.is_none()
			|| witness.room != request.room
			|| witness.selection != request.access
			|| witness.intent != request.bridge
			|| witness.credentials != request.credentials
		{
			return Err(loam::refusal(
				"only the successful original continuing bridge intent may be reapplied",
			));
		}
		let original_source = record
			.custody
			.session_access(witness.source)
			.ok_or_else(|| loam::refusal("original bridge source custody is absent"))?
			.reference
			.resolve(call, input)?;
		let original_access = resolve(
			&record,
			witness
				.access
				.ok_or_else(|| loam::refusal("original bridge continuing access is absent"))?,
			call,
			input,
		)?;
		if source != original_source || targets.get(1) != Some(&original_access) {
			return Err(loam::refusal("original bridge source and continuing access required"));
		}
		id
	} else {
		if record.bridges.as_slice().len() == bridge::MAX_WITNESSES {
			return Err(loam::refusal("bridge witnesses are full"));
		}
		if record.custody.next_identity().get() == 0 {
			return Err(loam::refusal("private identities exhausted"));
		}
		let id = NonZeroU64::new(record.custody.next_identity().get().max(owner.next_line.get()))
			.ok_or_else(|| loam::refusal("private identities exhausted"))?;
		let value = SafeInteger::new(id.get()).ok_or_else(|| loam::refusal("private identities exhausted"))?;
		let mut allocator = Allocator::new(&record, id);
		let source_key = allocator.allocate(custody::Role::SessionAccess)?;
		record
			.custody
			.insert_session_access(Held {
				key: source_key,
				reference: Field::Held(source.clone()),
			})
			.map_err(|_| loam::refusal("bridge source custody is full"))?;
		// AcceptedAccess is a connection-lived visit in this session phase.
		// Only actual RoomAccess permits fresh membership after the original seat.
		let access = request
			.access
			.filter(|selection| selection.role == custody::Role::RoomAccess)
			.map(|selection| -> Result<Coordinate> {
				let key = allocator.allocate(selection.role)?;
				let coordinate = Coordinate {
					role: selection.role,
					key,
				};
				record
					.custody
					.insert(records::restored(coordinate, Field::Held(targets[1].clone())))
					.map_err(|_| loam::refusal("bridge access custody is full"))?;
				Ok(coordinate)
			})
			.transpose()?;
		record
			.custody
			.set_next_identity(SafeInteger::new(id.get() + 1).unwrap_or(SafeInteger::ZERO));
		owner.next_line.set(id.get() + 1);
		record
			.bridges
			.try_push(bridge::Witness {
				id: value,
				operation: request.operation.clone(),
				room: request.room.clone(),
				source: source_key,
				selection: request.access,
				access,
				intent: request.bridge.clone(),
				credentials: request.credentials.clone(),
				applied: false,
			})
			.map_err(|_| loam::refusal("bridge witnesses are full"))?;
		value
	};
	let seat = Seat::reserve(
		owner,
		request
			.operation
			.text()
			.as_str()
			.ok_or_else(|| loam::refusal("invalid bridge operation"))?,
	)?;
	let (reservation, pending) = call.reserve_continuation_copying(&targets)?;
	let source = reservation.source()?;
	let retained = coordinates
		.into_iter()
		.zip(targets)
		.map(|(key, target)| records::restored(key, Field::Held(target)))
		.collect();
	let receipt = content::receipt(input, request.operation.clone(), intent, source.clone(), retained)?;
	content::reserve(owner, &mut record, receipt)?;
	if request.reapply.is_none() {
		records::replace(call, input, &mut record)?;
	} else {
		records::replace_effects(call, input, &record)?;
	}
	seat.start_bridge(
		pending,
		source,
		canonical,
		super::pipeline::Intent {
			request,
			id,
			secrets,
			credentials,
		},
	)?;
	Ok("pending".into())
}
fn resolve(
	record: &records::Record,
	coordinate: Coordinate,
	call: &mut Call<'_>,
	input: Invocation<'_>,
) -> Result<Ref> {
	let held = record
		.custody
		.get(coordinate)
		.ok_or_else(|| loam::refusal("bridge custody is absent"))?;
	records::reference(&held).resolve(call, input)
}
