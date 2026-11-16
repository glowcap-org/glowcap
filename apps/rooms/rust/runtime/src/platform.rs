//! Platform execution required by room and direct message effects.
use crate::{clock::Clock, wall_clock::WallClock};
use core::future::Future;
use rooms_glowcap::client::{Deadline, Tasks};
use tokio::task::{AbortHandle, JoinHandle};
pub trait Platform: Clock + WallClock + Deadline + Tasks + Clone + 'static {}
impl<T: Clock + WallClock + Deadline + Tasks + Clone + 'static> Platform for T {}

/// A task spawned on the current local set. Dropping the handle aborts the
/// task, so its work ends with its owner and never outlives it.
pub struct OwnedTask(JoinHandle<()>);

impl OwnedTask {
	/// Spawn `work` on the current local set.
	pub fn spawn_local(work: impl Future<Output = ()> + 'static) -> Self {
		Self(tokio::task::spawn_local(work))
	}

	/// A handle that aborts the task without owning it.
	pub fn abort_handle(&self) -> AbortHandle {
		self.0.abort_handle()
	}
}

impl Drop for OwnedTask {
	fn drop(&mut self) {
		self.0.abort();
	}
}
