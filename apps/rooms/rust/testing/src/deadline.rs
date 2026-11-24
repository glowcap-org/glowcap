//! A test clock that misses the bounded waits a test names and answers every
//! other one as the clock it wraps does.

use rooms_glowcap::client::Deadline;
use std::{cell::Cell, future::Future, ops::Range, rc::Rc, time::Duration};

/// What a missed wait does with its work.
#[derive(Clone, Copy)]
pub enum Miss {
	/// The work is dropped unpolled, so its answer is never awaited. A call
	/// that sends before its bound, as `Caller::call` does, has still reached
	/// the far side.
	Unstarted,
	/// The work runs until the runtime's timer first fires and is then
	/// dropped, so it starts and outlasts its bound.
	Started,
}

/// A clock that numbers its bounded waits from zero and misses those in its
/// window. Clones share the counts.
#[derive(Clone)]
pub struct Scripted<D> {
	inner: D,
	waits: Rc<Cell<usize>>,
	gave_up: Rc<Cell<usize>>,
	missed: Range<usize>,
	miss: Miss,
}

impl<D> Scripted<D> {
	/// Miss the waits numbered in `missed` as `miss` says, and answer the rest
	/// as `inner` does.
	pub fn new(inner: D, missed: Range<usize>, miss: Miss) -> Self {
		Self {
			inner,
			waits: Rc::default(),
			gave_up: Rc::default(),
			missed,
			miss,
		}
	}

	/// How many waits this clock gave up on before their work finished. A
	/// wait in the window whose work finishes on its first poll is not one.
	pub fn gave_up(&self) -> usize {
		self.gave_up.get()
	}
}

impl<D: Deadline> Deadline for Scripted<D> {
	fn monotonic_millis(&self) -> u64 {
		self.inner.monotonic_millis()
	}

	async fn within<T>(&self, milliseconds: u64, work: impl Future<Output = T>) -> Option<T> {
		let wait = self.waits.get();
		self.waits.set(wait + 1);
		if !self.missed.contains(&wait) {
			return self.inner.within(milliseconds, work).await;
		}
		let answer = match self.miss {
			Miss::Unstarted => None,
			Miss::Started => tokio::time::timeout(Duration::ZERO, work).await.ok(),
		};
		if answer.is_none() {
			self.gave_up.set(self.gave_up.get() + 1);
		}
		answer
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	/// A clock that answers every wait it is asked to run with its work.
	struct Prompt;
	impl Deadline for Prompt {
		fn monotonic_millis(&self) -> u64 {
			0
		}
		async fn within<T>(&self, _: u64, work: impl Future<Output = T>) -> Option<T> {
			Some(work.await)
		}
	}

	#[tokio::test(flavor = "current_thread")]
	async fn only_a_wait_whose_work_did_not_finish_is_given_up() {
		let clock = Scripted::new(Prompt, 0..2, Miss::Started);
		assert_eq!(clock.within(1, async { 7 }).await, Some(7));
		assert_eq!(clock.within(1, std::future::pending::<()>()).await, None);
		assert_eq!(clock.within(1, async { 8 }).await, Some(8));
		assert_eq!(clock.gave_up(), 1);
	}
}
