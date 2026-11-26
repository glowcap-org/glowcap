//! When the loop reads and how long it waits after a read fails. The verdicts
//! a failed read carries are owned by `access_of` in `engine/env.rs`: this
//! file only decides pacing from them, slow for an access a person changes
//! and standard for a connection.
use super::{Backoff, Env, env::access_of};
use crate::bot::{
	rooms::{Rooms, RoomsError},
	status::{Access, Activity},
	store::Store,
};
use std::time::Duration;
use tokio::time::Instant;

/// Triggers waiting for room in the ledger. Past it the bot stops reading,
/// and the session keeps what it has not delivered.
const MAX_QUEUED: usize = 256;

/// Whether the loop schedules a read now. A full queue stops reading so the
/// session keeps what the bot cannot hold, except while the access is not
/// active: the read is then the only call that can see the access resume,
/// and it fails until it does, so it delivers nothing. The first read after
/// the resume may deliver one batch past the bound, and then the bound holds
/// again. While the loop holds after a failed state write (`Loop::hold`),
/// nothing reads.
pub(super) fn wanted(queued: usize, access: Access, held: bool) -> bool {
	!held && (queued < MAX_QUEUED || access != Access::Active)
}

/// When the next read is due and how it asks, from how the reads before it
/// went.
pub(super) struct ReadPace {
	standard: Backoff,
	slow: Backoff,
	/// The first read, and the one after a failed read, returns at once, so
	/// the session's answer to a new link, and access that came back, show
	/// without waiting out a read of a quiet session.
	pub failing: bool,
	pub read_at: Instant,
	/// The failure the log last named.
	reported: Option<String>,
}

impl ReadPace {
	pub fn new() -> Self {
		Self {
			standard: Backoff::standard(),
			slow: Backoff::slow(),
			failing: true,
			read_at: Instant::now(),
			reported: None,
		}
	}

	/// A read succeeded.
	pub fn read<R: Rooms>(&mut self, env: &Env<'_, R>) {
		self.failing = false;
		self.standard.reset();
		self.slow.reset();
		if self.reported.take().is_some() {
			env.store.log("receiving: reading events works again");
		}
	}

	/// The next read is due after `wait`, and returns at once.
	pub fn retry_after(&mut self, wait: Duration) {
		self.failing = true;
		self.read_at = Instant::now() + wait;
	}

	/// A read failed: record what it says about access, and wait.
	pub fn failed<R: Rooms>(&mut self, env: &Env<'_, R>, error: &RoomsError) {
		env.access_failed(Activity::Receiving, error);
		env.publish();
		let wait = read_backoff(
			env.store,
			"receiving",
			error,
			[&mut self.standard, &mut self.slow],
			&mut self.reported,
		);
		self.retry_after(wait);
	}
}

/// The wait after a failed read of activity. Paused and revoked access
/// (`env::access_of`) changes only when a person acts, so it waits on the slow
/// steps and a connection failure on the standard ones. The log names a failure
/// once, after `during`. `reported` holds the one it last named, so a read
/// that fails the same way again adds no line.
pub(super) fn read_backoff(
	store: &Store,
	during: &str,
	error: &RoomsError,
	[standard, slow]: [&mut Backoff; 2],
	reported: &mut Option<String>,
) -> Duration {
	let text = error.to_string();
	if reported.as_deref() != Some(text.as_str()) {
		store.log(&format!("{during}: {text}"));
		*reported = Some(text);
	}
	match access_of(error.kind) {
		Some(_) => slow.next(),
		None => standard.next(),
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn a_full_queue_stops_reading_only_while_the_access_is_active() {
		for access in [Access::Unknown, Access::Paused, Access::Revoked] {
			assert!(wanted(MAX_QUEUED, access, false), "{access:?} must keep probing");
		}
		assert!(wanted(MAX_QUEUED - 1, Access::Active, false));
		assert!(!wanted(MAX_QUEUED, Access::Active, false));
		assert!(!wanted(0, Access::Paused, true), "a held turn waits before it reads");
	}
}
