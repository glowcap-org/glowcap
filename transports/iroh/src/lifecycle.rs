use std::future::Future;
use std::panic::resume_unwind;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};

use tokio::runtime::{Handle, Runtime};
use tokio::task::JoinHandle;

/// Own the endpoint's private runtime without ever dropping it through Tokio's
/// panicking in-runtime destructor. Sidecar calls may legally originate from a
/// Rust application already inside another Tokio runtime.
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

	pub(crate) fn spawn<F>(&self, future: F) -> JoinHandle<F::Output>
	where
		F: Future + Send + 'static,
		F::Output: Send + 'static,
	{
		self.get().spawn(future)
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

/// Endpoint-surviving ownership for writers detached from released connection
/// handles. The barrier retains failure until endpoint release, after every
/// admitted writer has either finished or spent its bounded drain deadline.
pub(crate) struct WriterTasks {
	state: Mutex<WriterState>,
	drained: Condvar,
}

struct WriterState {
	active: usize,
	failed: bool,
}

impl WriterTasks {
	pub(crate) fn new() -> Self {
		Self {
			state: Mutex::new(WriterState {
				active: 0,
				failed: false,
			}),
			drained: Condvar::new(),
		}
	}

	pub(crate) fn acquire(self: &Arc<Self>) -> WriterPermit {
		self.lock().active += 1;
		WriterPermit {
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

	/// These critical sections contain only counters and a boolean. No callback,
	/// allocation, or transport operation runs while held, so recovering the
	/// container after an unrelated panic is safe and avoids a second panic.
	fn lock(&self) -> MutexGuard<'_, WriterState> {
		self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
	}
}

pub(crate) struct WriterPermit {
	owner: Arc<WriterTasks>,
	succeeded: bool,
}

impl WriterPermit {
	pub(crate) fn succeed(mut self) {
		self.succeeded = true;
	}
}

impl Drop for WriterPermit {
	fn drop(&mut self) {
		let mut state = self.owner.lock();
		state.failed |= !self.succeeded;
		state.active -= 1;
		if state.active == 0 {
			self.owner.drained.notify_all();
		}
	}
}
