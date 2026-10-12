//! Bounded completion ownership for accepted introductions and reciprocal routes.
//! A viewer never drives these effects, and close observes the original calls.
use super::{InboxOrigin, State};
use glowcap::{Argument, Result, loam};
use rooms_application::{content::session::workspace::InboxSelection, directory::registration};
use rooms_glowcap::client::{Deadline, Tasks};
use sha2::{Digest, Sha256};
use std::{
	collections::BTreeMap,
	rc::{Rc, Weak},
};

const MAX_PENDING: usize = 32;
#[cfg(test)]
mod tests;
pub(super) struct Pending<P: Tasks> {
	request: Rc<Request>,
	_task: P::Task,
	failure: Option<glowcap::Error>,
}
struct Request {
	source: glowcap::Ref,
	verb: &'static str,
	args: Vec<Argument>,
}
pub(super) type PendingCalls<P> = BTreeMap<String, Pending<P>>;

pub(super) fn accept<P: Tasks + Deadline + Clone + 'static>(
	state: &Weak<State<P>>,
	origin: &InboxOrigin,
	event: &registration::Event,
) -> Result<()> {
	let Some((selected @ InboxSelection::Directory { .. }, callback)) = origin.installed() else {
		return Err(loam::refusal("introduction has no original directory callback"));
	};
	let opening = event
		.opening
		.as_ref()
		.ok_or_else(|| loam::refusal("introduction requires its opening identity"))?;
	let encoded = serde_json::to_string(selected).map_err(|_| loam::refusal("invalid introduction origin"))?;
	// Full callback identity includes exact directory/source generations. The
	// bounded display ID neither reconstructs authority nor aliases nicknames.
	struct Hash(Sha256);
	impl std::io::Write for Hash {
		fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
			self.0.update(bytes);
			Ok(bytes.len())
		}
		fn flush(&mut self) -> std::io::Result<()> {
			Ok(())
		}
	}
	let mut hash = Hash(Sha256::new());
	serde_json::to_writer(
		&mut hash,
		&(selected, &event.peer, event.registration.as_str(), opening),
	)
	.map_err(|_| loam::refusal("invalid introduction identity"))?;
	let mut id = String::with_capacity(71);
	id.push_str("direct:");
	use std::fmt::Write;
	for byte in hash.0.finalize() {
		let _ = write!(&mut id, "{byte:02x}");
	}
	queue(
		state,
		origin,
		Request {
			source: origin.source().clone(),
			verb: "accept-direct-introduction",
			args: vec![
				encoded.into(),
				callback.clone().into(),
				id.into(),
				event
					.peer
					.text()
					.as_str()
					.ok_or_else(|| loam::refusal("invalid direct peer"))?
					.into(),
				event.registration.as_str().into(),
				opening
					.text()
					.as_str()
					.ok_or_else(|| loam::refusal("invalid opening identity"))?
					.into(),
			],
		},
	)
}
pub(super) fn route<P: Tasks + Deadline + Clone + 'static>(
	state: &Weak<State<P>>,
	origin: &InboxOrigin,
	reference: &glowcap::Ref,
) -> Result<()> {
	let Some((selected @ InboxSelection::Direct { .. }, callback)) = origin.installed() else {
		return Err(loam::refusal("reciprocal route has no original direct callback"));
	};
	let encoded = serde_json::to_string(selected).map_err(|_| loam::refusal("invalid reciprocal origin"))?;
	queue(
		state,
		origin,
		Request {
			source: origin.source().clone(),
			verb: "adopt-direct-route",
			args: vec![
				encoded.into(),
				callback.clone().into(),
				reference.clone().into(),
				origin.route_ordinal()?.into(),
			],
		},
	)
}
fn queue<P: Tasks + Deadline + Clone + 'static>(
	owner: &Weak<State<P>>,
	origin: &InboxOrigin,
	request: Request,
) -> Result<()> {
	let state = owner
		.upgrade()
		.ok_or_else(|| loam::refusal("session introduction owner has closed"))?;
	if state.closing.get() || !origin.is_open() {
		return Err(loam::refusal("original introduction callback has closed"));
	}
	let identity = if request.verb == "accept-direct-introduction" {
		&request.args[2]
	} else {
		&request.args[0]
	};
	let identity = identity
		.as_str()
		.ok_or_else(|| loam::refusal("direct transition identity is not text"))?;
	let mut key = format!("{}:{}", request.verb, identity);
	if request.verb == "adopt-direct-route" {
		use std::fmt::Write;
		let ordinal = request.args[3]
			.as_i64()
			.ok_or_else(|| loam::refusal("direct route ordinal is not an integer"))?;
		let _ = write!(&mut key, ":{ordinal}");
	}
	let mut pending = state.introductions.borrow_mut();
	if let Some(previous) = pending.get(&key) {
		return if previous.request.source == request.source && previous.request.args == request.args {
			Ok(())
		} else {
			Err(loam::refusal("callback already retains another direct transition"))
		};
	}
	if pending.len() == MAX_PENDING {
		return Err(loam::refusal("session direct transitions are full"));
	}
	let request = Rc::new(request);
	let task = start(&state, owner.clone(), key.clone(), request.clone());
	pending.insert(
		key,
		Pending {
			request,
			_task: task,
			failure: None,
		},
	);
	Ok(())
}
fn start<P: Tasks + Deadline + Clone + 'static>(
	state: &Rc<State<P>>,
	owner: Weak<State<P>>,
	completion_key: String,
	executing: Rc<Request>,
) -> P::Task {
	let writer = state.writer.clone();
	state.platform.spawn(async move {
		let result = writer
			.idempotent_through(&executing.source, executing.verb, &executing.args)
			.await;
		if let Err(error) = &result {
			writer.report(executing.verb, error);
		}
		if let Some(state) = owner.upgrade() {
			let mut pending = state.introductions.borrow_mut();
			match result {
				Ok(_) => {
					pending.remove(&completion_key);
				}
				Err(error) => {
					// The writer reported this failure above; the entry keeps it
					// for the explicit retry when the transition is still retained.
					if let Some(entry) = pending.get_mut(&completion_key) {
						entry.failure = Some(error);
					}
				}
			}
			drop(pending);
			state.changed.notify_waiters();
		}
	})
}
pub(super) fn failure<P: Tasks>(pending: &PendingCalls<P>) -> Option<glowcap::Error> {
	pending.values().find_map(|entry| entry.failure.clone())
}
/// Explicit retry keeps each original source, callback and complete request.
/// A running call is observed by its existing task and is never redispatched.
pub(super) fn resume<P: Tasks + Deadline + Clone + 'static>(state: &Rc<State<P>>) {
	let mut pending = state.introductions.borrow_mut();
	for (key, entry) in pending.iter_mut().filter(|(_, entry)| entry.failure.is_some()) {
		entry.failure.take();
		entry._task = start(state, Rc::downgrade(state), key.clone(), entry.request.clone());
	}
}
