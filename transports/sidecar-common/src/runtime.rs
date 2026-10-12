use std::future::Future;
use std::panic::resume_unwind;

use tokio::runtime::{Handle, Runtime};
use tokio::task::JoinHandle;

/// Own the endpoint's private runtime without ever dropping it through Tokio's
/// panicking in-runtime destructor. Sidecar calls may legally originate from a
/// Rust application already inside another Tokio runtime: `Runtime::drop`
/// panics there, while `shutdown_background` is explicitly safe. Endpoint
/// teardown first joins every task its barrier admitted, so this is only the
/// final non-parking runtime reap.
pub struct RuntimeOwner(Option<Runtime>);

impl RuntimeOwner {
	pub fn new(runtime: Runtime) -> Self {
		Self(Some(runtime))
	}

	fn get(&self) -> &Runtime {
		self.0.as_ref().unwrap()
	}

	pub fn handle(&self) -> &Handle {
		self.get().handle()
	}

	/// Run one synchronous C-ABI operation on the endpoint's private runtime.
	/// Tokio refuses nested `Runtime::block_on`. A multithreaded ambient runtime
	/// yields its worker with `block_in_place`, while a current-thread runtime
	/// borrows one scoped helper thread instead of turning an ordinary library
	/// call into a panic.
	pub fn block_on<F>(&self, future: F) -> F::Output
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

	pub fn spawn<F>(&self, future: F) -> JoinHandle<F::Output>
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
