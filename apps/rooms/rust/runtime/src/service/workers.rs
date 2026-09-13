//! Named task custody for the shared session composition.
use super::{Stop, Worker, error::Error};
use std::future::Future;
use tokio::{sync::watch, task::JoinSet};

/// Every task the peer owns, named. A task that ends on its own is a peer
/// failure, and shutdown joins all of them before returning.
pub(super) struct Workers {
	set: JoinSet<(Worker, Result<(), Error>)>,
	stop: watch::Sender<bool>,
}

impl Workers {
	pub(super) fn new() -> Self {
		Self {
			set: JoinSet::new(),
			stop: watch::channel(false).0,
		}
	}
	pub(super) fn stop(&self) {
		self.stop.send_replace(true);
	}
	pub fn stop_signal(&self) -> Stop {
		self.stop.subscribe()
	}
	pub fn spawn(&mut self, worker: Worker, work: impl Future<Output = Result<(), Error>> + 'static) {
		self.set.spawn_local(async move { (worker, work.await) });
	}
	/// Resolve when any worker ends. Pending forever while none has, so a
	/// select arm can wait on it without a guard.
	pub(super) async fn ended(&mut self) -> Error {
		match self.set.join_next().await {
			Some(Ok((worker, outcome))) => Error::WorkerEnded {
				worker,
				cause: outcome.err().map(Box::new),
			},
			Some(Err(join)) => lost(join),
			None => std::future::pending().await,
		}
	}
	/// Stop the pumps and observe every worker's completion.
	pub(super) async fn join(&mut self) -> Result<(), Error> {
		self.stop.send_replace(true);
		let mut result = Ok(());
		while let Some(ended) = self.set.join_next().await {
			let outcome = match ended {
				Ok((_, outcome)) => outcome,
				Err(join) => Err(lost(join)),
			};
			result = Error::fold(result, outcome);
		}
		result
	}
}

/// A worker that neither returned nor unwound to us: it panicked, or the
/// runtime dropped the task. Whatever it had in flight never reached a caller,
/// so the session has to read its state again rather than ask again.
fn lost(join: tokio::task::JoinError) -> Error {
	Error::uncertain(format!("a session worker task failed: {join}"))
}
