//! Named task custody for the shared session composition.
use super::{error::Error, Stop};
use std::future::Future;
use tokio::{sync::watch, task::JoinSet};
/// Every task the peer owns, so a task that ends on its own names itself.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Worker {
	Storage,
	Grants,
	Directories,
	Rooms,
	Archive,
	DirectDispatch,
	DirectCommands,
	HandedRooms,
	RoomOffers,
	OfferOutcomes,
	DirectOutcomes,
	RoomEvents,
	DirectEvents,
	Changes,
	Reconciliation,
}

impl Worker {
	pub fn name(self) -> &'static str {
		match self {
			Self::Storage => "storage worker",
			Self::Grants => "grant worker",
			Self::Directories => "directory worker",
			Self::Rooms => "room worker",
			Self::Archive => "archive worker",
			Self::DirectDispatch => "direct dispatcher",
			Self::DirectCommands => "direct command worker",
			Self::HandedRooms => "handed-room worker",
			Self::RoomOffers => "room-offer worker",
			Self::OfferOutcomes => "room-offer outcome drain",
			Self::DirectOutcomes => "direct dispatch outcome drain",
			Self::RoomEvents => "room event pump",
			Self::DirectEvents => "direct event pump",
			Self::Changes => "change watcher",
			Self::Reconciliation => "operations reconciler",
		}
	}
}

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
			Some(Err(join)) => Error::runtime(format!("a session worker task failed: {join}")),
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
				Err(join) => Err(Error::runtime(format!("a session worker task failed: {join}"))),
			};
			result = Error::fold(result, outcome);
		}
		result
	}
}
