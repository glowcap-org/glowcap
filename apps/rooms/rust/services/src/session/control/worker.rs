//! One bounded disk queue; no filesystem operation runs on a Rooms turn.
use super::{failure::Failure, inbox::Inbox};
use serde_json::{Value, json};
use std::path::PathBuf;
use tokio::sync::{mpsc, oneshot, watch};

enum Work {
	Event(Value),
	Pending(oneshot::Sender<Result<Value, Failure>>),
	Ack(Vec<u64>, oneshot::Sender<Result<Value, Failure>>),
	Gap(Failure),
	Resume(oneshot::Sender<Result<Value, Failure>>),
	Close,
}
#[derive(Clone)]
pub struct Worker {
	tx: mpsc::Sender<Work>,
	failure: watch::Receiver<Option<Failure>>,
	wake: watch::Sender<()>,
}
pub struct Owner {
	pub worker: Worker,
	task: tokio::task::JoinHandle<Result<Inbox, Failure>>,
}
impl Owner {
	pub async fn open(path: PathBuf) -> Result<Self, Failure> {
		let (tx, mut rx) = mpsc::channel(128);
		let (changed, failure) = watch::channel(None);
		let (wake, _) = watch::channel(());
		let committed = wake.clone();
		let (ready, opened) = oneshot::channel();
		let task = tokio::task::spawn_blocking(move || {
			let mut inbox = Inbox::open(path)?;
			inbox.begin()?;
			changed.send_replace(inbox.gap());
			if ready.send(()).is_err() {
				return Err(Failure::uncertain("control initialization cancelled"));
			}
			let mut cursor = 0u64;
			while let Some(work) = rx.blocking_recv() {
				let mutation = !matches!(&work, Work::Pending(_) | Work::Close);
				match work {
					Work::Event(event) => {
						if let Err(error) = inbox.append(event) {
							let persisted = inbox.mark_gap(error.clone());
							changed.send_replace(Some(persisted.err().unwrap_or(error)));
						}
					}
					Work::Pending(reply) => {
						let mut pending = inbox.pending();
						pending["cursor"] = cursor.into();
						let _ = reply.send(Ok(pending));
					}
					Work::Ack(ids, reply) => {
						let result = inbox.acknowledge(&ids);
						if let Err(error) = &result {
							let persisted = inbox.mark_gap(error.clone());
							changed.send_replace(Some(persisted.err().unwrap_or_else(|| error.clone())));
						}
						let _ = reply.send(result);
					}
					Work::Gap(error) => {
						let persisted = inbox.mark_gap(error.clone());
						changed.send_replace(Some(persisted.err().unwrap_or(error)));
					}
					Work::Resume(reply) => {
						let result = inbox.resume().map(|()| {
							changed.send_replace(None);
							json!({"ok": true})
						});
						let _ = reply.send(result);
					}
					Work::Close => {
						inbox.close()?;
						return Ok(inbox);
					}
				}
				if mutation {
					cursor = cursor
						.checked_add(1)
						.ok_or_else(|| Failure::exhausted("inbox change cursor exhausted"))?;
					committed.send_replace(());
				}
			}
			Err(Failure::uncertain("inbox owner disappeared before shutdown"))
		});
		match opened.await {
			Ok(()) => Ok(Self {
				worker: Worker { tx, failure, wake },
				task,
			}),
			Err(_) => {
				// The join result owns the failure; readiness is only a signal.
				let _retired = task.await.map_err(Failure::uncertain)??;
				Err(Failure::uncertain("inbox ended before reporting readiness"))
			}
		}
	}
	pub async fn close(self) -> Result<Inbox, Failure> {
		let sent = self.worker.tx.send(Work::Close).await;
		let inbox = self.task.await.map_err(Failure::uncertain)??;
		sent.map_err(|_| Failure::uncertain("inbox worker ended before shutdown"))?;
		Ok(inbox)
	}
}
impl Worker {
	pub fn updates(&self) -> watch::Receiver<()> {
		self.wake.subscribe()
	}
	pub fn wake(&self) {
		self.wake.send_replace(());
	}
	pub fn failure(&self) -> Option<Failure> {
		self.failure.borrow().clone()
	}
	pub fn event(&self, event: Value) -> Result<(), Failure> {
		if let Some(error) = self.failure() {
			return Err(error);
		}
		self.tx.try_send(Work::Event(event)).map_err(|error| match error {
			mpsc::error::TrySendError::Full(_) => Failure::exhausted("inbox disk queue full; observation has a gap"),
			mpsc::error::TrySendError::Closed(_) => {
				Failure::uncertain("inbox disk worker ended; restart before resuming")
			}
		})
	}
	pub async fn gap(&self, error: Failure) -> Result<(), Failure> {
		self.tx
			.send(Work::Gap(error))
			.await
			.map_err(|_| Failure::uncertain("inbox worker ended"))
	}
	pub async fn pending(&self) -> Result<Value, Failure> {
		let (reply, result) = oneshot::channel();
		self.tx
			.send(Work::Pending(reply))
			.await
			.map_err(|_| Failure::uncertain("inbox worker ended"))?;
		result.await.map_err(Failure::uncertain)?
	}
	pub async fn ack(&self, ids: Vec<u64>) -> Result<Value, Failure> {
		let (reply, result) = oneshot::channel();
		self.tx
			.send(Work::Ack(ids, reply))
			.await
			.map_err(|_| Failure::uncertain("inbox worker ended"))?;
		result.await.map_err(Failure::uncertain)?
	}
	pub async fn resume(&self) -> Result<Value, Failure> {
		let (reply, result) = oneshot::channel();
		self.tx
			.send(Work::Resume(reply))
			.await
			.map_err(|_| Failure::uncertain("inbox worker ended"))?;
		result.await.map_err(Failure::uncertain)?
	}
}
