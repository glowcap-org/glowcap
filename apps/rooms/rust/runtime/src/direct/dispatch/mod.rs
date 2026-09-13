//! Session-local scheduling for direct registration effects and outgoing route
//! requests. The worker owns operation futures; callers only observe outcomes.
mod worker;
use crate::Error;
use crate::direct::publications::Platform;
use crate::{
	direct::openings::RouteOpenings,
	direct::publications::DirectPublications,
	direct::routes::RouteReceiver,
	directories::runtime::{AcceptedDirect, DirectoryRuntime, REGISTRATION_LIMIT, RegistrationInbox, RegistrationWork},
};
use glowcap::Behavior;
use rooms_glowcap::client::{Error as ClientError, direct::publisher::Publisher};
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
};
use tokio::sync::{mpsc, oneshot, watch};
pub use worker::DirectWorker;

pub const OPERATION_LIMIT: usize = super::publications::OFFER_LIMIT;
pub const REQUEST_LIMIT: usize = 32;

#[derive(Clone)]
pub struct DirectDispatcher<P: Platform> {
	requests: mpsc::Sender<Request>,
	budget: Rc<Cell<usize>>,
	routes: RouteReceiver<P>,
	stop: watch::Sender<bool>,
	done: watch::Receiver<Option<Result<(), Error>>>,
}
/// Dropping this observation does not cancel the admitted opening.
pub struct Opening<P: Platform> {
	answer: oneshot::Receiver<Result<(), Error>>,
	context: AcceptedDirect,
	routes: RouteReceiver<P>,
	stop: watch::Receiver<bool>,
	done: watch::Receiver<Option<Result<(), Error>>>,
	_permit: Rc<RequestPermit>,
}
struct Request {
	context: AcceptedDirect,
	reply: Reply,
}
struct Reply {
	answer: oneshot::Sender<Result<(), Error>>,
	_permit: Rc<RequestPermit>,
}
struct RequestPermit(Rc<Cell<usize>>);
impl Drop for RequestPermit {
	fn drop(&mut self) {
		self.0.set(self.0.get() - 1);
	}
}
pub enum Effect {
	Published(AcceptedDirect),
	RouteEstablished,
	NotAccepted,
	Introducible,
}
/// The original registration permit stays charged through delivery and until
/// the consumer drops this outcome. Check work.current() before new effects.
pub struct Outcome {
	pub work: Rc<RegistrationWork>,
	pub result: Result<Effect, Error>,
}
pub struct Outcomes(mpsc::Receiver<Outcome>);
impl Outcomes {
	pub async fn next(&mut self) -> Option<Outcome> {
		self.0.recv().await
	}
}
fn dispatcher_retired() -> Error {
	Error::closed("the direct dispatcher or conversation has retired")
}
impl<P: Platform> Opening<P> {
	pub async fn wait(mut self) -> Result<(), Error> {
		self.require_current()?;
		(&mut self.answer)
			.await
			.map_err(|_| Error::closed("the direct dispatcher ended without answering"))??;
		self.require_current()?;
		if !self.routes.live(&self.context) {
			return Err(Error::closed("the opened direct route has retired"));
		}
		Ok(())
	}
	fn require_current(&self) -> Result<(), Error> {
		if *self.stop.borrow()
			|| self.stop.has_changed().is_err()
			|| self.done.borrow().is_some()
			|| self.done.has_changed().is_err()
			|| !self.routes.current(&self.context)
		{
			return Err(dispatcher_retired());
		}
		Ok(())
	}
}
impl<P: Platform> DirectDispatcher<P> {
	/// Drive the returned worker on the session local executor and consume its outcomes.
	/// The parent retains DirectRoutes and the receiver's effect owners. The one
	/// factory supplies both published inboxes and introduced reply actors.
	pub fn new(
		runtime: DirectoryRuntime<P>,
		inbox: RegistrationInbox,
		publisher: Publisher<P>,
		routes: RouteReceiver<P>,
		report_cleanup: Rc<dyn Fn(Error)>,
		make: impl FnMut(AcceptedDirect) -> Result<Behavior, ClientError> + 'static,
	) -> (Self, DirectWorker<P>, Outcomes) {
		let make = Rc::new(RefCell::new(make));
		let published = make.clone();
		let publications = Rc::new(DirectPublications::new(publisher, move |context| {
			published.borrow_mut()(context)
		}));
		let openings = RouteOpenings::new(runtime.clone(), routes.clone(), move |context| {
			make.borrow_mut()(context)
		});
		let (requests, requested) = mpsc::channel(REQUEST_LIMIT);
		let (outcomes, observed) = mpsc::channel(REGISTRATION_LIMIT);
		let (stop, stopping) = watch::channel(false);
		let (finished, done) = watch::channel(None);
		let worker = DirectWorker {
			runtime,
			inbox,
			publications,
			openings,
			routes: routes.clone(),
			requests: requested,
			outcomes,
			stopping,
			finished,
			pending: Vec::new(),
			cleanup: None,
			report_cleanup,
		};
		(
			Self {
				requests,
				budget: Rc::new(Cell::new(0)),
				routes,
				stop,
				done,
			},
			worker,
			Outcomes(observed),
		)
	}
	/// Admission is synchronous and bounded. Outgoing and reverse requests share
	/// the worker's exact-context opening owner and its introduction attempts.
	pub fn ensure(&self, context: &AcceptedDirect) -> Result<Opening<P>, Error> {
		if *self.stop.borrow() || self.done.borrow().is_some() || !context.current() {
			return Err(dispatcher_retired());
		}
		if self.budget.get() == REQUEST_LIMIT {
			return Err(Error::busy("the direct request budget is full"));
		}
		self.budget.set(self.budget.get() + 1);
		let permit = Rc::new(RequestPermit(self.budget.clone()));
		let (answer, receiver) = oneshot::channel();
		self.requests
			.try_send(Request {
				context: context.clone(),
				reply: Reply {
					answer,
					_permit: permit.clone(),
				},
			})
			.map_err(|error| match error {
				mpsc::error::TrySendError::Full(_) => Error::busy("the direct request queue is full"),
				mpsc::error::TrySendError::Closed(_) => Error::closed("the direct dispatcher has ended"),
			})?;
		Ok(Opening {
			answer: receiver,
			context: context.clone(),
			routes: self.routes.clone(),
			stop: self.stop.subscribe(),
			done: self.done.clone(),
			_permit: permit,
		})
	}
	pub fn retire(&self) {
		self.stop.send_replace(true);
	}
	/// The worker observes its opening tasks and publication cleanup before this
	/// completes. Cancelling this observation does not cancel that shutdown.
	pub async fn close(&self) -> Result<(), Error> {
		self.retire();
		let mut done = self.done.clone();
		loop {
			if let Some(result) = done.borrow().clone() {
				return result;
			}
			done.changed()
				.await
				.map_err(|_| Error::closed("the direct worker retired without completing shutdown"))?;
		}
	}
}
