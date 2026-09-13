use std::sync::{Arc, Condvar, Mutex, MutexGuard};

/// The endpoint-surviving owner for tasks detached from a released handle: a
/// writer whose connection handle is gone, a peer still closing after its
/// handle was freed. The barrier retains the outstanding count and the first
/// failure bit until endpoint release claims them, after every admitted task
/// has either finished or spent its bounded deadline.
pub struct TaskBarrier {
	state: Mutex<BarrierState>,
	drained: Condvar,
}

struct BarrierState {
	active: usize,
	failed: bool,
}

/// One or more tasks admitted to a teardown barrier ended without explicitly
/// committing success. This includes cancellation and panic as well as a
/// reported task failure; the barrier cannot safely erase any of them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TaskFailure;

impl std::fmt::Display for TaskFailure {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		f.write_str("an admitted task did not complete successfully")
	}
}

impl std::error::Error for TaskFailure {}

impl TaskBarrier {
	pub fn new() -> Self {
		Self {
			state: Mutex::new(BarrierState {
				active: 0,
				failed: false,
			}),
			drained: Condvar::new(),
		}
	}

	pub fn acquire(self: &Arc<Self>) -> TaskPermit {
		self.lock().active += 1;
		TaskPermit {
			owner: self.clone(),
			succeeded: false,
		}
	}

	pub fn record_failure(&self) {
		self.lock().failed = true;
	}

	pub fn wait(&self) -> Result<(), TaskFailure> {
		let mut state = self.lock();
		while state.active != 0 {
			state = self
				.drained
				.wait(state)
				.unwrap_or_else(|poisoned| poisoned.into_inner());
		}
		if state.failed { Err(TaskFailure) } else { Ok(()) }
	}

	/// These critical sections contain counters and a boolean only; no callback,
	/// allocation, or fallible transport operation runs while held. Recovering a
	/// poisoned container is therefore safe and keeps an unrelated panic from
	/// turning the library's release barrier into another panic.
	fn lock(&self) -> MutexGuard<'_, BarrierState> {
		self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
	}
}

impl Default for TaskBarrier {
	fn default() -> Self {
		Self::new()
	}
}

/// Failure-by-default admission for one task. A normal result explicitly
/// marks success; cancellation or panic drops the permit unfinished and is
/// therefore retained as a teardown failure instead of disappearing with the
/// Tokio `JoinHandle`.
pub struct TaskPermit {
	owner: Arc<TaskBarrier>,
	succeeded: bool,
}

impl TaskPermit {
	pub fn succeed(mut self) {
		self.succeeded = true;
	}
}

impl Drop for TaskPermit {
	fn drop(&mut self) {
		let mut state = self.owner.lock();
		state.failed |= !self.succeeded;
		state.active -= 1;
		if state.active == 0 {
			self.owner.drained.notify_all();
		}
	}
}

#[cfg(test)]
mod barrier_tests {
	use super::*;

	#[test]
	fn an_unfinished_permit_fails_the_barrier() {
		let tasks = Arc::new(TaskBarrier::new());
		drop(tasks.acquire());
		assert_eq!(tasks.wait(), Err(TaskFailure));
	}

	#[test]
	fn a_finished_permit_leaves_the_barrier_green() {
		let tasks = Arc::new(TaskBarrier::new());
		tasks.acquire().succeed();
		assert_eq!(tasks.wait(), Ok(()));
	}
}
