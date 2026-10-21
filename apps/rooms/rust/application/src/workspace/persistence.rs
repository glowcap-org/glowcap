//! Bounded save admission and retry policy. The adapter owns two cancellable
//! timers and performs synchronous storage calls. No document queue is kept.
use alloc::string::String;
const FIRST_RETRY_MS: u32 = 1_000;
const MAX_RETRY_MS: u32 = 30_000;

pub struct Persistence {
	last: Option<String>,
	dirty: bool,
	blocked: bool,
	stopped: bool,
	active: bool,
	save_pending: bool,
	retry_pending: bool,
	retry_delay: u32,
	refused: Option<String>,
	storage_failure: bool,
}
pub struct Attempt {
	prepared: bool,
	was_dirty: bool,
}
pub struct Failed {
	pub report: bool,
	pub retry_ms: Option<u32>,
}
impl Persistence {
	pub fn new(last: Option<String>, blocked: bool) -> Self {
		Self {
			last,
			dirty: false,
			blocked,
			stopped: false,
			active: false,
			save_pending: false,
			retry_pending: false,
			retry_delay: FIRST_RETRY_MS,
			refused: None,
			storage_failure: false,
		}
	}
	pub fn blocked(&self) -> bool {
		self.blocked
	}
	pub fn stopped(&self) -> bool {
		self.stopped
	}
	pub fn last(&self) -> Option<&str> {
		self.last.as_deref()
	}
	pub fn set_blocked(&mut self, blocked: bool) {
		self.blocked = blocked;
	}
	pub fn dirty(&self) -> bool {
		self.dirty
	}
	pub fn current(&self) -> bool {
		self.active && !self.stopped && !self.blocked
	}
	/// True requests the sole coalescing timer. Further changes only mark dirty.
	pub fn schedule(&mut self) -> bool {
		if self.stopped || self.blocked {
			return false;
		}
		self.dirty = true;
		if self.save_pending {
			return false;
		}
		self.save_pending = true;
		true
	}
	pub fn retry_fired(&mut self) {
		self.retry_pending = false;
	}
	/// Cancels the coalescing deadline. A prepared transition cannot replace a
	/// save recursively while its read or storage adapter is running.
	pub fn begin(&mut self, prepared: bool) -> Option<Attempt> {
		if self.stopped || self.blocked || self.active {
			return None;
		}
		self.active = true;
		self.save_pending = false;
		Some(Attempt {
			prepared,
			was_dirty: core::mem::replace(&mut self.dirty, false),
		})
	}
	pub fn unchanged(&self, document: &str) -> bool {
		self.last.as_deref() == Some(document)
	}
	pub fn refused(&mut self, reason: String) -> bool {
		self.active = false;
		let reason = crate::failure::reason_prefix(&reason).into();
		if self.stopped || self.refused.as_ref() == Some(&reason) {
			return false;
		}
		self.refused = Some(reason);
		true
	}
	pub fn cancel(&mut self) {
		self.active = false;
	}
	pub fn saved(&mut self, document: Option<String>) {
		self.active = false;
		if self.stopped {
			return;
		}
		if let Some(document) = document {
			self.last = Some(document);
		}
		self.refused = None;
		self.storage_failure = false;
		self.retry_pending = false;
		self.retry_delay = FIRST_RETRY_MS;
	}
	pub fn failed(&mut self, attempt: Attempt) -> Failed {
		self.active = false;
		if self.stopped {
			return Failed {
				report: false,
				retry_ms: None,
			};
		}
		self.refused = None;
		let report = !core::mem::replace(&mut self.storage_failure, true);
		// A refused transition is never retried with its new controller. Only
		// pre-existing dirty state authorizes retrying the current workspace.
		if attempt.prepared && attempt.was_dirty {
			self.dirty = true;
		}
		let retry_ms = if (!attempt.prepared || attempt.was_dirty) && !self.retry_pending {
			self.retry_pending = true;
			let delay = self.retry_delay;
			self.retry_delay = (delay * 2).min(MAX_RETRY_MS);
			Some(delay)
		} else {
			None
		};
		Failed { report, retry_ms }
	}
	pub fn stop(&mut self) {
		self.stopped = true;
		self.active = false;
		self.dirty = false;
		self.save_pending = false;
		self.retry_pending = false;
		self.last = None;
		self.refused = None;
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn refused_transition_retries_only_prior_dirty_state_and_stop_fences_it() {
		let mut saves = Persistence::new(Some("old workspace".into()), false);
		let clean_transition = saves.begin(true).unwrap();
		assert!(saves.failed(clean_transition).retry_ms.is_none());
		assert!(saves.unchanged("old workspace"));
		assert!(saves.schedule());
		let dirty_transition = saves.begin(true).unwrap();
		assert!(
			saves.begin(false).is_none(),
			"a callback cannot recursively replace the active write"
		);
		assert_eq!(saves.failed(dirty_transition).retry_ms, Some(FIRST_RETRY_MS));
		assert!(saves.dirty());
		saves.retry_fired();
		let _retry = saves.begin(false).unwrap();
		assert!(saves.schedule(), "a change arriving during a write needs a later save");
		saves.saved(Some("current workspace".into()));
		assert!(saves.dirty(), "acknowledgement must preserve newer dirty state");
		saves.stop();
		saves.set_blocked(false);
		assert!(!saves.schedule());
		assert!(saves.begin(false).is_none());
	}
}
