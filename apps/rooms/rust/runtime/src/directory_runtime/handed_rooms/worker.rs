use super::*;
use std::{future::poll_fn, task::Poll};
type Pending = Pin<Box<dyn Future<Output = ()>>>;

pub struct HandedWorker<P: Platform> {
	state: Rc<State<P>>,
	finished: watch::Sender<Option<Result<(), String>>>,
	pending: Vec<Pending>,
}
impl<P: Platform> HandedWorker<P> {
	pub(super) fn new(state: Rc<State<P>>, finished: watch::Sender<Option<Result<(), String>>>) -> Self {
		Self {
			state,
			finished,
			pending: Vec::new(),
		}
	}
	/// The parent retains this worker's task and observes completion. No
	/// receipt, expiry observer, or acceptance starts a detached task.
	pub async fn run(mut self) -> Result<(), String> {
		self.drive().await;
		self.state.retire();
		self.admit();
		while !self.pending.is_empty() {
			let index = ready(&mut self.pending).await;
			drop(self.pending.remove(index));
		}
		self.finished.send_replace(Some(Ok(())));
		Ok(())
	}
	fn admit(&mut self) {
		for job in self.state.queued.borrow_mut().drain(..) {
			self.pending.push(Box::pin(job.run(self.state.clone())));
		}
	}
	async fn drive(&mut self) {
		let mut changed = self.state.changed.subscribe();
		let mut stop = self.state.stop.subscribe();
		let mut directory_stop = self.state.directory_stop.clone();
		let mut directory_done = self.state.directory_done.clone();
		loop {
			if self.state.require_open().is_err() {
				return;
			}
			self.state.reconcile();
			self.admit();
			tokio::select! {
				_ = changed.changed() => {},
				_ = stop.changed() => {},
				_ = directory_stop.changed() => {},
				_ = directory_done.changed() => {},
				id = expired(&self.state) => { self.state.remove(&id); },
				index = ready(&mut self.pending) => { drop(self.pending.remove(index)); },
			}
		}
	}
}
impl<P: Platform> Drop for HandedWorker<P> {
	fn drop(&mut self) {
		self.state.retire();
		// This is failure reporting, not evidence of completed storage work.
		// SessionCommands retains any transaction that was already sent.
		for job in self.state.jobs.borrow().iter().filter_map(Weak::upgrade) {
			job.abandoned();
		}
		self.state.queued.borrow_mut().clear();
	}
}
async fn ready(pending: &mut [Pending]) -> usize {
	poll_fn(|cx| {
		for (index, future) in pending.iter_mut().enumerate() {
			if future.as_mut().poll(cx).is_ready() {
				return Poll::Ready(index);
			}
		}
		Poll::Pending
	})
	.await
}
async fn expired<P: Platform>(state: &State<P>) -> Id {
	poll_fn(|cx| {
		for row in state.rows.borrow().rows() {
			if row.value().expiry.borrow_mut().as_mut().poll(cx).is_ready() {
				return Poll::Ready(row.view().id.clone());
			}
		}
		Poll::Pending
	})
	.await
}
