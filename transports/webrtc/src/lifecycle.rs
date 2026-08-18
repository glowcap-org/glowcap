use std::future::Future;
use std::panic::resume_unwind;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};

use tokio::runtime::{Handle, Runtime};

/// Own the Tokio runtime behind an endpoint. `Runtime::drop` panics when it
/// runs inside an ambient async context; `shutdown_background` is explicitly
/// safe there. Endpoint teardown first joins every peer-close task, so this is
/// only the final non-parking runtime reap.
pub(crate) struct RuntimeOwner(Option<Runtime>);

impl RuntimeOwner {
	pub(crate) fn new(runtime: Runtime) -> Self {
		Self(Some(runtime))
	}

	fn get(&self) -> &Runtime {
		self.0.as_ref().unwrap()
	}

	pub(crate) fn handle(&self) -> &Handle {
		self.get().handle()
	}

	/// Run one synchronous C-ABI operation on the endpoint's private runtime.
	/// Tokio refuses nested `Runtime::block_on`; a multithreaded ambient runtime
	/// yields its worker with `block_in_place`, while a current-thread runtime
	/// borrows one scoped helper thread instead of turning an ordinary library
	/// call into a panic.
	pub(crate) fn block_on<F>(&self, future: F) -> F::Output
	where
		F: Future + Send,
		F::Output: Send,
	{
		if let Ok(ambient) = Handle::try_current() {
			if ambient.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread {
				return tokio::task::block_in_place(|| self.get().block_on(future));
			}
			return std::thread::scope(|scope| match scope.spawn(|| self.get().block_on(future)).join() {
				Ok(value) => value,
				Err(panic) => resume_unwind(panic),
			});
		}
		self.get().block_on(future)
	}
}

impl Drop for RuntimeOwner {
	fn drop(&mut self) {
		if let Some(runtime) = self.0.take() {
			runtime.shutdown_background();
		}
	}
}

#[cfg(test)]
mod runtime_tests {
	use super::*;

	#[test]
	fn private_runtime_calls_work_inside_an_ambient_runtime() {
		let private = RuntimeOwner::new(
			tokio::runtime::Builder::new_multi_thread()
				.worker_threads(1)
				.enable_all()
				.build()
				.unwrap(),
		);
		let ambient = tokio::runtime::Builder::new_current_thread()
			.enable_all()
			.build()
			.unwrap();
		ambient.block_on(async {
			assert_eq!(private.block_on(async { 42 }), 42);
		});
	}

	#[test]
	fn private_runtime_calls_work_inside_a_multithreaded_ambient_runtime() {
		let private = RuntimeOwner::new(
			tokio::runtime::Builder::new_multi_thread()
				.worker_threads(1)
				.enable_all()
				.build()
				.unwrap(),
		);
		let ambient = tokio::runtime::Builder::new_multi_thread()
			.worker_threads(1)
			.enable_all()
			.build()
			.unwrap();
		ambient.block_on(async {
			assert_eq!(private.block_on(async { 42 }), 42);
		});
	}
}

/// The endpoint-surviving owner for asynchronous peer close. A peer handle can
/// disappear before WebRTC finishes closing its connection, so the endpoint
/// retains both the outstanding count and the first failure bit until its
/// explicit release barrier claims them.
pub(crate) struct CloseTasks {
	state: Mutex<CloseState>,
	drained: Condvar,
}

struct CloseState {
	active: usize,
	failed: bool,
}

impl CloseTasks {
	pub(crate) fn new() -> Self {
		Self {
			state: Mutex::new(CloseState {
				active: 0,
				failed: false,
			}),
			drained: Condvar::new(),
		}
	}

	pub(crate) fn acquire(self: &Arc<Self>) -> ClosePermit {
		self.lock().active += 1;
		ClosePermit {
			owner: self.clone(),
			succeeded: false,
		}
	}

	pub(crate) fn record_failure(&self) {
		self.lock().failed = true;
	}

	pub(crate) fn wait(&self) -> Result<(), ()> {
		let mut state = self.lock();
		while state.active != 0 {
			state = self
				.drained
				.wait(state)
				.unwrap_or_else(|poisoned| poisoned.into_inner());
		}
		if state.failed {
			Err(())
		} else {
			Ok(())
		}
	}

	/// These critical sections contain counters and a boolean only; no callback,
	/// allocation, or fallible transport operation runs while held. Recovering a
	/// poisoned container is therefore safe and keeps an unrelated panic from
	/// turning the library's release barrier into another panic.
	fn lock(&self) -> MutexGuard<'_, CloseState> {
		self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
	}
}

/// Failure-by-default admission for one close task. A normal result explicitly
/// marks success; cancellation or panic drops the permit unfinished and is
/// therefore retained as a teardown failure instead of disappearing with the
/// Tokio `JoinHandle`.
pub(crate) struct ClosePermit {
	owner: Arc<CloseTasks>,
	succeeded: bool,
}

impl ClosePermit {
	pub(crate) fn succeed(mut self) {
		self.succeeded = true;
	}
}

impl Drop for ClosePermit {
	fn drop(&mut self) {
		let mut state = self.owner.lock();
		state.failed |= !self.succeeded;
		state.active -= 1;
		if state.active == 0 {
			self.owner.drained.notify_all();
		}
	}
}
