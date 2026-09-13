use super::*;
use crate::direct::outgoing::OutgoingWorker;
use std::{
	future::{Future, poll_fn},
	pin::Pin,
	task::Poll,
};
pub(super) struct Pending {
	context: AcceptedDirect,
	work: Pin<Box<dyn Future<Output = ()>>>,
}
pub struct CommandWorker<P: Platform> {
	pub(super) platform: P,
	pub(super) commands: SessionCommands,
	pub(super) delivery: DirectOutgoing<P>,
	pub(super) delivery_worker: Option<OutgoingWorker<P>>,
	pub(super) task: Option<tokio::task::JoinHandle<Result<(), Error>>>,
	pub(super) requests: mpsc::Receiver<Request>,
	pub(super) stopping: watch::Receiver<bool>,
	pub(super) cancel: watch::Sender<bool>,
	pub(super) finished: watch::Sender<Option<Result<(), Error>>>,
	pub(super) pending: Vec<Pending>,
	pub(super) queued: Vec<Request>,
}
impl<P: Platform> CommandWorker<P> {
	pub async fn run(mut self) -> Result<(), Error> {
		self.task = Some(tokio::task::spawn_local(
			self.delivery_worker.take().expect("unstarted delivery worker").run(),
		));
		let mut child_failure = None;
		loop {
			if *self.stopping.borrow() || self.stopping.has_changed().is_err() {
				break;
			}
			tokio::select! {
				_ = self.stopping.changed() => {},
				result = self.task.as_mut().expect("running delivery worker") => {
					self.task.take();
					child_failure = Some(match result {
						Ok(Err(error)) => error,
						Err(error) => Error::closed(error.to_string()),
						Ok(Ok(())) => Error::closed("outgoing worker ended unexpectedly"),
					});
					break;
				},
				request = self.requests.recv(), if self.pending.len() + self.queued.len() < LIMIT => {
					let Some(request) = request else { break; };
					if self.busy(&request.context) { self.queued.push(request); } else { self.start(request); }
				},
				index = ready(&mut self.pending) => {
					self.pending.remove(index);
					if let Some(at) = self.queued.iter().position(|r| !self.busy(&r.context)) {
						let request = self.queued.remove(at);
						self.start(request);
					}
				}
			}
		}
		self.requests.close();
		self.cancel.send_replace(true);
		for request in self.queued.drain(..) {
			refuse(request);
		}
		while let Ok(request) = self.requests.try_recv() {
			refuse(request);
		}
		let mut result = self.delivery.close().await;
		if let Some(task) = self.task.take() {
			match task.await {
				Ok(Ok(())) => {}
				Ok(Err(error)) => result = Err(error),
				Err(error) => result = Err(Error::closed(error.to_string())),
			}
		}
		// Delivery is stopped and observed. Finish admitted ledger writes and
		// record known-not-sent abandonment; preparation observes cancellation.
		while !self.pending.is_empty() {
			let index = ready(&mut self.pending).await;
			self.pending.remove(index);
		}
		if let Some(error) = child_failure {
			result = Err(error);
		}
		self.finished.send_replace(Some(result.clone()));
		result
	}
	fn busy(&self, context: &AcceptedDirect) -> bool {
		self.pending.iter().any(|p| p.context.same_context(context))
	}
	fn start(&mut self, request: Request) {
		self.pending.push(Pending {
			context: request.context.clone(),
			work: Box::pin(execution::run(
				self.platform.clone(),
				self.commands.clone(),
				self.delivery.clone(),
				request,
				self.cancel.subscribe(),
			)),
		});
	}
}
impl<P: Platform> Drop for CommandWorker<P> {
	fn drop(&mut self) {
		self.requests.close();
		if let Some(task) = self.task.take() {
			task.abort();
		}
	}
}
fn refuse(request: Request) {
	let _ = request.answer.send(Err(CommandFailure {
		delivery: Delivery::NotSent,
		ledger: Ledger::Unrecorded,
		cause: Error::closed("direct commands stopped before preparation"),
	}));
}
async fn ready(pending: &mut [Pending]) -> usize {
	poll_fn(|cx| {
		for (index, pending) in pending.iter_mut().enumerate() {
			if pending.work.as_mut().poll(cx).is_ready() {
				return Poll::Ready(index);
			}
		}
		Poll::Pending
	})
	.await
}
