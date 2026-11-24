//! Manager recovery reads the witnessed seat's identity before the operator
//! acts. The identity is observed here, never supplied by the request, and the
//! seat and entrance never reach the operator.
use super::{
	State,
	content::{self, connection},
	executor::Seat,
	records,
};
use glowcap::{
	Argument, Ref, Result,
	loam::{self, Call, Continuation, Invocation, ReadInterface, ReadMethod, ReferenceRequest},
};
use rooms_application::{
	content::session::{
		custody::{self, FieldKey},
		recovery::Witness,
		workspace,
	},
	fields::Text,
	room::ArgumentView,
	session::command::{Effect, Request, Route},
};
use rooms_glowcap::client::{Deadline, Tasks};
use std::{pin::Pin, rc::Rc};

/// The longest identity this worker retains. The server's own correlator is far
/// shorter. The bound keeps retained and forwarded text finite.
const MAX_IDENTITY_UNITS: usize = 32768;

pub(super) fn recognizes(route: Route) -> bool {
	route == Route::Effect(Effect::RecoverRoomManager)
}
struct Selected {
	operator: custody::Coordinate,
	seat: custody::Coordinate,
	entrance: Option<custody::Coordinate>,
}
fn selection(request: &Request<'_, impl ArgumentView>, intent: &workspace::Intent) -> Result<Selected> {
	let args: Vec<_> = request.args().collect();
	let [operator, witness] = args.as_slice() else {
		return Err(loam::refusal("manager recovery takes an operator and a room witness"));
	};
	let operator: FieldKey<custody::Operator> =
		serde_json::from_str(operator).map_err(|_| loam::refusal("invalid manager recovery operator"))?;
	if !intent.operators.as_slice().contains(&operator) {
		return Err(loam::refusal("selected operator is not held in this workspace"));
	}
	let witness = Witness::parse(witness).map_err(|_| loam::refusal("invalid manager recovery room"))?;
	let room = witness
		.id
		.text()
		.as_str()
		.and_then(|id| intent.room(id))
		.ok_or_else(|| loam::refusal("recovery room is no longer held"))?;
	if !witness.matches(room) || room.control.is_some() {
		return Err(loam::refusal("recovery room has changed or already has a manager"));
	}
	let entrance = witness.entrance();
	if entrance.is_none() && (room.access.is_some() || room.accepted.is_some() || room.public_entry.is_some()) {
		return Err(loam::refusal("recovery room has no single entrance"));
	}
	Ok(Selected {
		operator: custody::Coordinate::new(custody::Role::Operator, operator),
		seat: witness.seat_coordinate(),
		entrance,
	})
}
pub(super) fn references(input: Invocation<'_>, record: &content::MetadataRecord) -> Result<Vec<ReferenceRequest>> {
	let declared = content::values(input.args);
	let request = Request::parse(&declared).map_err(|error| loam::refusal(error.to_string()))?;
	let selected = selection(&request, &record.intent)?;
	[Some(selected.operator), Some(selected.seat), selected.entrance]
		.into_iter()
		.flatten()
		.map(|coordinate| {
			let held = record
				.custody
				.get(coordinate)
				.ok_or_else(|| loam::refusal("manager recovery custody is absent"))?;
			let location = records::location(&held);
			Ok(ReferenceRequest::RestorePage {
				page: location
					.page
					.checked_sub(1)
					.ok_or_else(|| loam::refusal("invalid manager recovery page"))?,
				field: location.field,
			})
		})
		.collect()
}
/// The operator and seat must be exported by one actual session. `None` does
/// not prove locality: `connection::exporter` reports it for a local reference
/// and for a stale one alike. Two `None` values pass here, and a stale seat then
/// fails its identity read before any operator call.
fn same_exporter(left: Option<glowcap::Session>, right: Option<glowcap::Session>) -> bool {
	match (left, right) {
		(Some(left), Some(right)) => left.same_session(&right),
		(None, None) => true,
		_ => false,
	}
}
pub(super) fn admit<P: Tasks + Deadline + Clone + 'static>(
	owner: &Rc<State<P>>,
	call: &mut Call<'_>,
	input: Invocation<'_>,
	mut record: records::Record,
	request: &Request<'_, impl ArgumentView>,
) -> Result<Argument> {
	let selected = selection(request, &record.intent)?;
	let resolve = |call: &mut Call<'_>, coordinate| {
		let held = record
			.custody
			.get(coordinate)
			.ok_or_else(|| loam::refusal("manager recovery custody is absent"))?;
		records::reference(&held).resolve(call, input)
	};
	let operator = resolve(call, selected.operator)?;
	let seat = resolve(call, selected.seat)?;
	let host = &owner.writer.host;
	let affine = same_exporter(
		connection::exporter(host, call, &operator)?,
		connection::exporter(host, call, &seat)?,
	);
	if !affine {
		return Err(loam::refusal("operator and room seat belong to different sessions"));
	}
	let entrance = selected
		.entrance
		.map(|coordinate| resolve(call, coordinate))
		.transpose()?;
	let reserved = Seat::reserve(owner, request.id(), record.effects.as_slice())?;
	let targets = [operator, seat];
	let (reservation, pending) = call.reserve_continuation_copying(&targets)?;
	let source = reservation.source()?;
	let canonical = request
		.canonical()
		.map_err(|_| loam::refusal("invalid manager recovery intent"))?;
	let operation =
		Text::new(request.id().into()).ok_or_else(|| loam::refusal("invalid manager recovery operation"))?;
	let intent = Text::new(canonical.clone().into())
		.ok_or_else(|| loam::refusal("manager recovery intent exceeds receipt capacity"))?;
	let [operator, seat] = targets;
	let mut retained = vec![
		records::restored(selected.operator, records::Field::Held(operator)),
		records::restored(selected.seat, records::Field::Held(seat)),
	];
	if let (Some(coordinate), Some(held)) = (selected.entrance, entrance) {
		retained.push(records::restored(coordinate, records::Field::Held(held)));
	}
	let receipt = content::commands::receipt(input, operation, intent, source.clone(), retained)?;
	content::commands::reserve(owner, &mut record, receipt)?;
	records::replace_effects(call, input, &record)?;
	reserved.start_manager(pending, source, canonical)?;
	Ok("pending".into())
}

type Reading = Pin<Box<dyn std::future::Future<Output = Result<Argument>>>>;
enum Phase {
	/// The continuation still owns the operator and no read has started.
	Ready(Continuation),
	/// One identity read is in flight. It stays here when `advance` is dropped.
	Reading { continuation: Continuation, read: Reading },
	/// The continuation went to the operator step.
	Identified,
}
/// The confirmed identity read keeps its one future across observation
/// deadlines. A terminal read refusal never reaches the operator.
pub(super) struct Pipeline {
	host: glowcap::Host,
	phase: Phase,
}
pub(super) enum Step {
	/// The verified identity and the continuation that still owns the operator.
	Identified(Continuation, String),
	/// The identity could not be read or is invalid. No operator call occurred.
	Refused(glowcap::Error),
}
impl Pipeline {
	pub fn new(host: glowcap::Host, continuation: Continuation) -> Self {
		Self {
			host,
			phase: Phase::Ready(continuation),
		}
	}
	fn reader(continuation: &Continuation) -> Result<Ref> {
		let methods = [ReadMethod {
			verb: rooms_application::room::authority::MANAGED_IDENTITY,
			results: &[],
		}];
		continuation.project_reads_copying(1, &[ReadInterface { methods: &methods }], 0)
	}
	fn validated(value: &Argument) -> Result<String> {
		let identity = value
			.as_str()
			.ok_or_else(|| loam::refusal("room seat answered no management identity"))?;
		if !Text::<MAX_IDENTITY_UNITS, true>::accepts_utf16(identity.encode_utf16()) {
			return Err(loam::refusal("room seat management identity is empty or too long"));
		}
		Ok(identity.to_owned())
	}
	pub async fn advance(&mut self) -> Result<Step> {
		if let Phase::Ready(continuation) = &self.phase {
			match Self::reader(continuation) {
				Ok(reader) => {
					let host = self.host.clone();
					let read: Reading = Box::pin(async move {
						host.send(&reader, rooms_application::room::authority::MANAGED_IDENTITY, &[])
							.await
					});
					if let Phase::Ready(continuation) = std::mem::replace(&mut self.phase, Phase::Identified) {
						self.phase = Phase::Reading { continuation, read };
					}
				}
				Err(error) => return Ok(Step::Refused(error)),
			}
		}
		// The future is polled where it is stored, so a dropped `advance` loses nothing.
		let Phase::Reading { read, .. } = &mut self.phase else {
			return Err(loam::refusal("manager recovery was already identified"));
		};
		let observed = read.await;
		let Phase::Reading { continuation, .. } = std::mem::replace(&mut self.phase, Phase::Identified) else {
			return Err(loam::refusal("manager recovery was already identified"));
		};
		match observed.and_then(|value| Self::validated(&value)) {
			Ok(identity) => Ok(Step::Identified(continuation, identity)),
			Err(error) => {
				self.phase = Phase::Ready(continuation);
				Ok(Step::Refused(error))
			}
		}
	}
}
