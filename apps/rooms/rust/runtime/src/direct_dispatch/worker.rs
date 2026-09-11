use super::*;
use rooms_application::directory::registration::Kind;
use std::{
	future::{poll_fn, Future},
	pin::Pin,
	task::Poll,
};

type Operation = Pin<Box<dyn Future<Output = Result<Effect, String>>>>;
type Cleanup = Pin<Box<dyn Future<Output = Result<(), String>>>>;
pub(super) enum Destination {
	Notice(Rc<RegistrationWork>),
	Request(Reply),
}
pub(super) struct Pending {
	destination: Destination,
	operation: Operation,
}
pub struct DirectWorker<P: Platform> {
	pub(super) runtime: DirectoryRuntime<P>,
	pub(super) inbox: RegistrationInbox,
	pub(super) publications: Rc<DirectPublications<P>>,
	pub(super) openings: RouteOpenings<P>,
	pub(super) routes: RouteReceiver<P>,
	pub(super) requests: mpsc::Receiver<Request>,
	pub(super) outcomes: mpsc::Sender<Outcome>,
	pub(super) stopping: watch::Receiver<bool>,
	pub(super) finished: watch::Sender<Option<Result<(), String>>>,
	pub(super) pending: Vec<Pending>,
	pub(super) cleanup: Option<Cleanup>,
}
impl<P: Platform> DirectWorker<P> {
	/// Retain and await this task through shutdown. Dropping run retires actors
	/// and aborts owned openings but cannot report observed task completion.
	pub async fn run(mut self) -> Result<(), String> {
		let mut result = self.drive().await;
		self.retire();
		self.cleanup = None;
		while let Some(pending) = self.pending.pop() {
			let Pending { destination, operation } = pending;
			drop(operation);
			combine(
				&mut result,
				self.complete(destination, Err("the direct dispatcher has retired".into())),
			);
		}
		while let Ok(request) = self.requests.try_recv() {
			let _ = request
				.reply
				.answer
				.send(Err("the direct dispatcher has retired".into()));
		}
		combine(&mut result, self.openings.close().await);
		combine(&mut result, self.publications.close().await);
		self.finished.send_replace(Some(result.clone()));
		result
	}
	async fn drive(&mut self) -> Result<(), String> {
		let mut changed = self.runtime.changes();
		let mut routes = self.routes.changes()?;
		let mut dirty = true;
		loop {
			if *self.stopping.borrow() || self.stopping.has_changed().is_err() {
				return Ok(());
			}
			if self.runtime.is_closed() {
				return Err("the directory runtime has ended".into());
			}
			if dirty && self.cleanup.is_none() {
				self.routes.reconcile()?;
				let publications = self.publications.clone();
				let routes = self.routes.clone();
				self.cleanup = Some(Box::pin(async move {
					let mut result = publications.reconcile().await;
					combine(&mut result, routes.retire_sessions().await);
					result
				}));
				dirty = false;
			}
			tokio::select! {
				_ = self.stopping.changed() => {},
				_ = self.outcomes.closed() => return Err("the direct outcome consumer has ended".into()),
				change = changed.changed() => {
					change.map_err(|_| "the directory runtime has ended")?;
					dirty = true;
				},
				change = routes.changed() => {
					change.map_err(|_| "the direct route owner has ended")?;
					self.routes.reconcile()?;
				},
				result = cleaned(&mut self.cleanup), if self.cleanup.is_some() => {
					self.cleanup = None;
					result?;
				},
				(index, result) = ready(&mut self.pending) => {
					let Pending { destination, operation } = self.pending.remove(index);
					drop(operation);
					self.complete(destination, result)?;
					let remaining = self.pending.len();
					if remaining != 0 { self.pending.rotate_left(index % remaining); }
				},
				work = self.inbox.next(), if self.pending.len() < OPERATION_LIMIT => {
					self.notice(work.ok_or("the directory registration inbox has ended")?)?;
				},
				request = self.requests.recv(), if self.pending.len() < OPERATION_LIMIT => {
					let Some(request) = request else { return Ok(()); };
					let operation = self.openings.ensure(&request.context);
					self.pending.push(Pending {
						destination: Destination::Request(request.reply),
						operation: Box::pin(async move { operation?.wait().await.map(|_| Effect::RouteEstablished) }),
					});
				},
			}
		}
	}
	fn notice(&mut self, work: RegistrationWork) -> Result<(), String> {
		let work = Rc::new(work);
		let operation: Operation = match work.event().kind {
			Kind::Introducible => {
				// Registration already woke introduction waiters before enqueueing.
				return self.complete(Destination::Notice(work), Ok(Effect::Introducible));
			}
			Kind::DirectRequested => {
				let requested = self.openings.requested(&work);
				Box::pin(async move {
					match requested? {
						Some(requested) => requested.establish().await.map(|_| Effect::RouteEstablished),
						None => Ok(Effect::NotAccepted),
					}
				})
			}
			Kind::MintInboxFor => {
				let (publications, runtime) = (self.publications.clone(), self.runtime.clone());
				let offered = work.clone();
				Box::pin(async move { publications.offer(&runtime, &offered).await.map(Effect::Published) })
			}
		};
		self.pending.push(Pending {
			destination: Destination::Notice(work),
			operation,
		});
		Ok(())
	}
	fn complete(&self, destination: Destination, result: Result<Effect, String>) -> Result<(), String> {
		let result = result.map_err(|error| rooms_application::failure::reason_prefix(&error).to_owned());
		let work = match destination {
			Destination::Notice(work) => work,
			Destination::Request(reply) => {
				let _ = reply.answer.send(result.map(|_| ()));
				return Ok(());
			}
		};
		self.outcomes
			.try_send(Outcome { work, result })
			.map_err(|error| match error {
				mpsc::error::TrySendError::Full(_) => "the direct outcome queue is full".into(),
				mpsc::error::TrySendError::Closed(_) => "the direct outcome consumer has ended".into(),
			})
	}
	fn retire(&mut self) {
		self.requests.close();
		self.inbox.close();
		self.publications.retire();
		self.openings.retire();
	}
}
impl<P: Platform> Drop for DirectWorker<P> {
	fn drop(&mut self) {
		self.retire();
	}
}
async fn ready(pending: &mut [Pending]) -> (usize, Result<Effect, String>) {
	poll_fn(|cx| {
		for (index, pending) in pending.iter_mut().enumerate() {
			if let Poll::Ready(result) = pending.operation.as_mut().poll(cx) {
				return Poll::Ready((index, result));
			}
		}
		Poll::Pending
	})
	.await
}
async fn cleaned(cleanup: &mut Option<Cleanup>) -> Result<(), String> {
	match cleanup {
		Some(cleanup) => cleanup.await,
		None => core::future::pending().await,
	}
}
fn combine(result: &mut Result<(), String>, next: Result<(), String>) {
	if let Err(error) = next {
		*result = Err(rooms_application::failure::reason_prefix(&match result {
			Ok(()) => error,
			Err(prior) => format!("{prior}; direct cleanup: {error}"),
		})
		.to_owned());
	}
}
