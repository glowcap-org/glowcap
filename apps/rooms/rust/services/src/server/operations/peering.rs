//! The peering capability: another directory's holder hands this server a
//! room under a name, the room resolves outside the turn, and from then on
//! the directory lists it and hands the same capability to whoever enters.
//! The lease answered back is the authority to take the listing down. The
//! publisher's session ending takes every listing it made down with it.
use super::super::{
	answer,
	state::{Shared, State, Work},
};
use glowcap::{Argument, Ref, Session, current_session};
use rooms_application::{
	directory::{OriginProof, registration::Id},
	server::{
		directory::Effects,
		peering::{MAX_ROOM, READY_TIMEOUT_MS, Source},
	},
};
use std::time::Duration;
use tokio::sync::watch;

const PUBLISH: &str = rooms_application::protocol_data::PUBLISH_DURABLE_ROOM;
const READY: &str = rooms_application::protocol_data::PUBLICATION_READY;
const DESCRIBE: &str = rooms_application::protocol_data::PUBLICATION_DESCRIBE;
const REVOKE: &str = rooms_application::protocol_data::REVOKE;

/// What a lease's `ready` waits on: nothing yet, live, or why not. status-allow: pending state or quoted runtime label
pub(crate) type Outcome = Option<Result<(), String>>;

pub(super) fn behavior(shared: Shared) -> impl FnMut(&str, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
		let session = current_session()
			.map_err(|e| e.to_string())?
			.ok_or("directory peering is reachable only over a session")?;
		if verb != PUBLISH {
			return Err(if super::carries_capability(args) {
				format!("directory peering {verb} does not take capability arguments")
			} else {
				format!("directory peering has no method {verb}")
			});
		}
		let shape = "publishDurableRoom needs a name of at most 32 characters and one room capability";
		let [Argument::String(name), Argument::Reference(room)] = args else {
			return Err(shape.into());
		};
		if name.is_empty() || name.chars().count() > MAX_ROOM {
			return Err(shape.into());
		}
		publish(&shared, &session, name, room.clone())
	}
}

/// Reserve the name, answer the lease, and resolve the handed room outside
/// the turn. The reservation is what the lease revokes before the room is
/// live, so nothing dangles whichever comes first.
fn publish(shared: &Shared, session: &Session, name: &str, room: Ref) -> Result<Argument, String> {
	let mut state = shared.borrow_mut();
	let connection = state.admit(session.borrowed());
	let source = source_of(session);
	let id = fresh_id(&state)?;
	let taken = state.rooms_name_taken(name) || state.irc.holds_name(name);
	let entry_id = {
		state
			.foreign
			.reserve(connection, name, source, id, |_| taken)
			.map_err(|refusal| refusal.reason())?
			.id
			.clone()
	};
	let (ready, _) = watch::channel::<Outcome>(None);
	state.peering_ready.insert(entry_id.clone(), ready.clone());
	// The seat is reserved on a clone of the queue's sender, so holding it
	// does not hold the state it came from.
	let work = state.work.clone();
	let seat = match work.try_reserve() {
		Ok(seat) => seat,
		Err(_) => {
			forget(&mut state, &entry_id);
			return Err(answer::busy());
		}
	};
	let resolving = match session.borrowed().listen(&room).into_admitted() {
		Ok(resolving) => resolving,
		Err(error) => {
			forget(&mut state, &entry_id);
			return Err(error.to_string());
		}
	};
	let lease = match session.spawn_owned(lease(shared.clone(), entry_id.clone())) {
		Ok(lease) => lease,
		Err(error) => {
			forget(&mut state, &entry_id);
			return Err(error.to_string());
		}
	};
	let shared = shared.clone();
	let waiting = entry_id.clone();
	seat.send(Work::Task(Box::pin(async move {
		let resolved = tokio::time::timeout(Duration::from_millis(READY_TIMEOUT_MS), resolving).await;
		let outcome = match resolved {
			Ok(Ok(Argument::Reference(live))) => Ok(live),
			Ok(Ok(_)) => Err("the handed room did not resolve to a capability".to_string()),
			Ok(Err(cause)) => Err(cause.to_string()),
			Err(_) => Err("the handed room did not resolve before the publication deadline".to_string()),
		};
		let mut state = shared.borrow_mut();
		let outcome = match outcome {
			Ok(live) => match state.foreign.commit(&waiting, live) {
				Some(event) => {
					let mut effects = Effects::default();
					effects.events.push(event);
					state.apply(effects);
					Ok(())
				}
				// Revoked or gone while resolving: nothing to list.
				None => Err("room publication was revoked before it became ready".to_string()),
			},
			Err(reason) => {
				forget(&mut state, &waiting);
				Err(reason)
			}
		};
		drop(room);
		if let Some(ready) = state.peering_ready.get(&waiting) {
			// Stored whether or not a lease is waiting yet: a `ready` asked status-allow: pending state or quoted runtime label
			// after the room resolved reads it back.
			ready.send_replace(Some(outcome));
		}
		state.changed();
	})));
	Ok(Argument::Reference(lease))
}

/// The lease over one publication: `ready` answers once the room is live
/// or why it never became so, and `revoke` takes the listing down. A lease
/// names its exact publication, so a stale one cannot touch a replacement.
fn lease(shared: Shared, id: String) -> impl FnMut(&str, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
		current_session()
			.map_err(|e| e.to_string())?
			.ok_or("a room publication lease is reachable only over a session")?;
		if super::carries_capability(args) {
			return Err(format!(
				"room publication lease {verb} does not take capability arguments"
			));
		}
		if !args.is_empty() && matches!(verb, READY | REVOKE | DESCRIBE) {
			return Err(format!("{verb} takes no arguments"));
		}
		match verb {
			DESCRIBE => {
				let state = shared.borrow();
				let phase = match state.peering_ready.get(&id).map(|ready| ready.borrow().clone()) {
					Some(None) => "publishing",
					Some(Some(Ok(()))) => "live",
					Some(Some(Err(_))) | None => "failed",
				};
				Ok(phase.into())
			}
			READY => {
				let state = shared.borrow();
				let Some(ready) = state.peering_ready.get(&id) else {
					return Err("room publication was revoked before it became ready".into());
				};
				let mut outcome = ready.subscribe();
				answer::later(
					&state,
					rooms_application::protocol_data::PUBLICATION_READY,
					async move {
						loop {
							if let Some(outcome) = outcome.borrow_and_update().clone() {
								return outcome.map(|()| Argument::Void);
							}
							if outcome.changed().await.is_err() {
								return Err("room publication was revoked before it became ready".into());
							}
						}
					},
				)
			}
			REVOKE => {
				let mut state = shared.borrow_mut();
				forget(&mut state, &id);
				state.changed();
				Ok(Argument::Void)
			}
			_ => Err(format!("room publication lease has no method {verb}")),
		}
	}
}

/// Take one publication out: a live one is announced closed and its room
/// let go. A pending one tells its lease why it never became ready.
pub(crate) fn forget(state: &mut State, id: &str) {
	if let Some(ready) = state.peering_ready.remove(id) {
		// tolerant: a lease no longer waiting hears nothing. status-allow: lifecycle transition
		ready.send_replace(Some(Err("room publication was revoked before it became ready".into())));
	}
	let Some((entry, event)) = state.foreign.forget(id) else {
		return;
	};
	if let Some(room) = entry.room {
		state.give_back(entry.connection, room);
	}
	if let Some(event) = event {
		let mut effects = Effects::default();
		effects.events.push(event);
		state.apply(effects);
	}
}

/// Who is publishing: a proved durable identity by its designator, or the
/// session by its key.
fn source_of(session: &Session) -> Source {
	match session.partner_identity() {
		Ok(identity) if identity.durable_identity_authenticated() && !identity.designator.is_empty() => Source {
			origin: identity.designator,
			proof: OriginProof::Authenticated,
		},
		Ok(identity) => Source {
			origin: identity.session_key.iter().map(|byte| format!("{byte:02x}")).collect(),
			proof: OriginProof::Session,
		},
		Err(_) => Source {
			origin: String::new(),
			proof: OriginProof::Session,
		},
	}
}

fn fresh_id(state: &State) -> Result<Id, String> {
	let mut bytes = [0u8; 16];
	for _ in 0..8 {
		rooms_platform::entropy::fill(&mut bytes).map_err(|e| format!("drawing a publication identity failed: {e}"))?;
		let id = Id::from_entropy(bytes);
		if state.foreign.by_id(id.as_str()).is_none()
			&& !state.rooms.entry_id_known(&id)
			&& state.authority.publication_room(id.as_str()).is_none()
		{
			return Ok(id);
		}
	}
	Err("publication identities are exhausted".into())
}

/// The peering rows an operator inventory reads.
pub(crate) fn faces(state: &State) -> Vec<rooms_application::server::operations::operator::inventory::ForeignFace> {
	state
		.foreign
		.entries()
		.map(
			|entry| rooms_application::server::operations::operator::inventory::ForeignFace {
				id: entry.id.clone(),
				name: entry.name.clone(),
				origin: entry.source.origin.clone(),
				proof: entry.source.proof.wire(),
				live: entry.is_live(),
			},
		)
		.collect()
}

impl State {
	/// The publisher's connection ended: every listing it made goes.
	pub fn forget_foreign_from(&mut self, connection: u64) {
		let ids: Vec<String> = self
			.foreign
			.entries()
			.filter(|entry| entry.connection == connection)
			.map(|entry| entry.id.clone())
			.collect();
		for id in ids {
			forget(self, &id);
		}
	}
}
