//! Control scheduling around real peer replies without replacing wire outcomes.
use rooms_glowcap::client::{Deadline, Tasks};
use rooms_platform::HostPlatform;
use rooms_runtime::{clock::Clock, wall_clock::WallClock};
use std::{
	cell::{Cell, RefCell},
	future::Future,
	rc::Rc,
	time::Duration,
};
use tokio::sync::oneshot;

#[derive(Clone, Default)]
pub(super) struct ControlledPlatform {
	offset: Rc<Cell<Duration>>,
	next: Rc<RefCell<Option<Next>>>,
}
enum Next {
	Timeout,
	Pause {
		reached: oneshot::Sender<()>,
		resume: oneshot::Receiver<()>,
	},
}
impl ControlledPlatform {
	pub(super) fn timeout_next(&self) {
		*self.next.borrow_mut() = Some(Next::Timeout);
	}
	pub(super) fn advance(&self, by: Duration) {
		self.offset.set(self.offset.get() + by);
	}
	pub(super) fn pause_next(&self) -> (oneshot::Receiver<()>, oneshot::Sender<()>) {
		let (reached, result) = oneshot::channel();
		let (release, resume) = oneshot::channel();
		*self.next.borrow_mut() = Some(Next::Pause { reached, resume });
		(result, release)
	}
}
impl Clock for ControlledPlatform {
	type Instant = tokio::time::Instant;
	fn now(&self) -> Self::Instant {
		HostPlatform.now() + self.offset.get()
	}
	async fn sleep_until(&self, at: Self::Instant) {
		HostPlatform.sleep_until(at - self.offset.get()).await;
	}
}
impl WallClock for ControlledPlatform {
	fn unix_millis(&self) -> Result<u64, rooms_runtime::wall_clock::Error> {
		HostPlatform.unix_millis()
	}
}
impl Tasks for ControlledPlatform {
	type Task = rooms_platform::execution::HostTask;
	fn spawn(&self, work: impl Future<Output = ()> + 'static) -> Self::Task {
		HostPlatform.spawn(work)
	}
}
impl Deadline for ControlledPlatform {
	async fn within<T>(&self, milliseconds: u64, work: impl Future<Output = T>) -> Option<T> {
		let next = self.next.borrow_mut().take();
		if matches!(next, Some(Next::Timeout)) {
			return None;
		}
		let result = HostPlatform.within(milliseconds, work).await;
		if let Some(Next::Pause { reached, resume }) = next {
			reached.send(()).unwrap();
			resume.await.unwrap();
		}
		result
	}
}
