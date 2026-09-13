//! The owner keeps one opening per exact conversation, independently of its
//! callers. Waiters observe completion; cancelling one does not cancel the work.
use crate::Error;
use crate::directories::runtime::Platform;
use crate::{
	direct::routes::RouteReceiver,
	directories::runtime::{AcceptedDirect, DirectoryRuntime, RegistrationWork},
};
use glowcap::Behavior;
use rooms_glowcap::client::{Error as ClientError, directory::Directory};
use std::{
	cell::{Cell, RefCell},
	future::Future,
	pin::Pin,
	rc::Rc,
	task::{Context, Poll, Waker},
	time::Duration,
};
use tokio::{sync::watch, task::JoinHandle};

pub const OPENING_LIMIT: usize = 32;
pub const WAITER_LIMIT: usize = 256;
type Outcome = Option<Result<(), Error>>;
type Factory = Rc<RefCell<dyn FnMut(AcceptedDirect) -> Result<Behavior, ClientError>>>;

pub struct RouteOpenings<P: Platform> {
	runtime: DirectoryRuntime<P>,
	routes: RouteReceiver<P>,
	make: Factory,
	stop: watch::Sender<bool>,
	rows: Vec<Opening>,
	waiters: Rc<Cell<usize>>,
	failure: Option<Error>,
}
struct Opening {
	context: AcceptedDirect,
	task: JoinHandle<()>,
	result: watch::Receiver<Outcome>,
}
pub struct RouteWaiter<P: Platform> {
	context: AcceptedDirect,
	routes: RouteReceiver<P>,
	stop: watch::Receiver<bool>,
	result: Option<watch::Receiver<Outcome>>,
	_permit: Permit,
}
/// The caller owns this acknowledgement operation through completion or
/// cancellation. It spends the waiter's budget until the wire call ends.
pub struct RequestedRoute<P: Platform>(RouteWaiter<P>);
struct Permit(Rc<Cell<usize>>);
impl Drop for Permit {
	fn drop(&mut self) {
		self.0.set(self.0.get() - 1);
	}
}
fn owner_retired() -> Error {
	Error::closed("the route opening owner or conversation has retired")
}
impl<P: Platform> RouteOpenings<P> {
	/// Call on the session's local executor. The factory supplies the full reply
	/// protocol; its returned behavior must not strongly retain its Host.
	pub fn new(
		runtime: DirectoryRuntime<P>,
		routes: RouteReceiver<P>,
		make: impl FnMut(AcceptedDirect) -> Result<Behavior, ClientError> + 'static,
	) -> Self {
		Self {
			runtime,
			routes,
			make: Rc::new(RefCell::new(make)),
			stop: watch::channel(false).0,
			rows: Vec::new(),
			waiters: Rc::new(Cell::new(0)),
			failure: None,
		}
	}
	pub fn ensure(&mut self, context: &AcceptedDirect) -> Result<RouteWaiter<P>, Error> {
		self.start(context, true)
	}
	/// A request for the reverse carrier cannot create intent or ask the peer
	/// for another reversal. Waiting shares any attempt already in progress.
	pub fn requested(&mut self, work: &RegistrationWork) -> Result<Option<RequestedRoute<P>>, Error> {
		if *self.stop.borrow() {
			return Err(Error::closed("the route opening owner has retired"));
		}
		let Some(context) = self.runtime.requested_direct(work)? else {
			return Ok(None);
		};
		Ok(Some(RequestedRoute(self.start(&context, false)?)))
	}
	fn start(&mut self, context: &AcceptedDirect, reciprocal: bool) -> Result<RouteWaiter<P>, Error> {
		if *self.stop.borrow() || !self.routes.current(context) {
			return Err(owner_retired());
		}
		if self.waiters.get() == WAITER_LIMIT {
			return Err(Error::busy("too many direct route waiters"));
		}
		self.waiters.set(self.waiters.get() + 1);
		let permit = Permit(self.waiters.clone());
		// Finished tasks retain no pending effects. Their waiters hold their own
		// result; a failed attempt does not permanently prevent another attempt.
		self.reap();
		let result = if self.routes.live(context) {
			None
		} else if let Some(row) = self.rows.iter().find(|row| row.context.same_context(context)) {
			Some(row.result.clone())
		} else {
			if self.rows.len() == OPENING_LIMIT {
				return Err(Error::busy("too many direct route openings"));
			}
			let directory = self.runtime.direct_directory(context)?;
			let (result, receiver) = watch::channel(None);
			let (runtime, routes, make, stop, accepted) = (
				self.runtime.clone(),
				self.routes.clone(),
				self.make.clone(),
				self.stop.subscribe(),
				context.clone(),
			);
			let task = tokio::task::spawn_local(async move {
				let completion = Completion(result);
				let result = drive(runtime, routes, make, stop, accepted, directory, reciprocal).await;
				completion.0.send_replace(Some(result));
			});
			self.rows.push(Opening {
				context: context.clone(),
				task,
				result: receiver.clone(),
			});
			Some(receiver)
		};
		Ok(RouteWaiter {
			context: context.clone(),
			routes: self.routes.clone(),
			stop: self.stop.subscribe(),
			result,
			_permit: permit,
		})
	}
	pub fn retire(&self) {
		self.stop.send_replace(true);
	}
	fn reap(&mut self) {
		let mut index = 0;
		while index < self.rows.len() {
			if self.rows[index].task.is_finished()
				&& let Poll::Ready(result) =
					Pin::new(&mut self.rows[index].task).poll(&mut Context::from_waker(Waker::noop()))
			{
				if let Err(error) = result {
					self.failure = Some(Error::closed(error.to_string()));
				}
				self.rows.remove(index);
				continue;
			}
			index += 1;
		}
	}
	/// Observe actual task retirement. Cancelling this close leaves every
	/// unobserved handle in the owner, so another close can finish the work.
	pub async fn close(&mut self) -> Result<(), Error> {
		self.retire();
		while let Some(row) = self.rows.first_mut() {
			if let Err(error) = (&mut row.task).await {
				self.failure = Some(Error::closed(error.to_string()));
			}
			self.rows.remove(0);
		}
		self.failure.clone().map_or(Ok(()), Err)
	}
}
impl<P: Platform> Drop for RouteOpenings<P> {
	fn drop(&mut self) {
		self.retire();
		for row in &self.rows {
			row.task.abort();
		}
	}
}
impl<P: Platform> RouteWaiter<P> {
	fn current(&self) -> bool {
		!*self.stop.borrow() && self.stop.has_changed().is_ok() && self.routes.current(&self.context)
	}
	pub async fn wait(mut self) -> Result<(), Error> {
		self.observe().await
	}
	async fn observe(&mut self) -> Result<(), Error> {
		loop {
			if !self.current() {
				return Err(owner_retired());
			}
			let Some(result) = self.result.as_mut() else { break };
			if let Some(outcome) = result.borrow().clone() {
				outcome?;
				break;
			}
			tokio::select! {
				_ = self.stop.changed() => {},
				changed = result.changed() => { changed.map_err(|_| Error::closed("the route opening stopped without an answer"))?; }
			}
		}
		if !self.current() || !self.routes.live(&self.context) {
			return Err(Error::closed("the opened route has retired"));
		}
		Ok(())
	}
}
impl<P: Platform> RequestedRoute<P> {
	pub async fn establish(mut self) -> Result<(), Error> {
		self.0.observe().await?;
		tokio::select! {
			biased;
			_ = self.0.stop.changed() => return Err(Error::closed("the route request owner has retired")),
			result = self.0.routes.announce(&self.0.context) => result?,
		}
		if !self.0.current() {
			return Err(Error::closed("the route request retired while being answered"));
		}
		Ok(())
	}
}
struct Completion(watch::Sender<Outcome>);
impl Drop for Completion {
	fn drop(&mut self) {
		if self.0.borrow().is_none() {
			self.0
				.send_replace(Some(Err(Error::closed("the route opening stopped before completion"))));
		}
	}
}

async fn drive<P: Platform>(
	runtime: DirectoryRuntime<P>,
	routes: RouteReceiver<P>,
	make: Factory,
	mut stop: watch::Receiver<bool>,
	context: AcceptedDirect,
	directory: Directory<P>,
	reciprocal: bool,
) -> Result<(), Error> {
	let mut intent = runtime.changes();
	let mut arrivals = routes.changes()?;
	let stopping = stop.clone();
	let work = open(&routes, &make, &stopping, &context, &directory, reciprocal);
	tokio::pin!(work);
	loop {
		if *stop.borrow() || stop.has_changed().is_err() || !routes.current(&context) {
			return Err(owner_retired());
		}
		if routes.live(&context) {
			return Ok(());
		}
		tokio::select! {
			biased;
			_ = stop.changed() => {},
			changed = intent.changed() => { changed.map_err(|_| Error::closed("the directory runtime has ended"))?; },
			changed = arrivals.changed() => { changed.map_err(|_| Error::closed("the direct route owner has ended"))?; },
			result = &mut work => return result,
		}
	}
}
async fn open<P: Platform>(
	routes: &RouteReceiver<P>,
	make: &Factory,
	stop: &watch::Receiver<bool>,
	context: &AcceptedDirect,
	directory: &Directory<P>,
	reciprocal: bool,
) -> Result<(), Error> {
	// An ordinary open announces nothing: the first message carries the reply
	// route. Only a route opened to answer a partner's reciprocal request
	// announces itself, from `RequestedRoute::establish`.
	let error = match connect(routes, make, stop, context, directory).await {
		Ok(()) => return Ok(()),
		Err(error) => error,
	};
	if !reciprocal || *stop.borrow() || !routes.current(context) {
		return Err(error);
	}
	if routes.live(context) {
		return Ok(());
	}
	// The reciprocal request is the recovery for the failed connect, so a
	// request that also fails is retained behind it.
	directory
		.request_direct(context.peer_name(), context.registration())
		.await
		.map_err(|request| error.clone().retain(Error::peer(request)))?;
	let platform = directory.client().platform();
	platform
		.sleep_until(platform.now() + Duration::from_millis(rooms_application::direct::RECIPROCAL_ROUTE_TIMEOUT_MS))
		.await;
	Err(Error::closed(format!(
		"the peer did not establish the requested reciprocal route: {error}"
	)))
}
async fn connect<P: Platform>(
	routes: &RouteReceiver<P>,
	make: &Factory,
	stop: &watch::Receiver<bool>,
	context: &AcceptedDirect,
	directory: &Directory<P>,
) -> Result<(), Error> {
	let direct = directory
		.direct(context.peer_name(), Some(context.registration()))
		.await
		.map_err(Error::peer)?;
	if *stop.borrow() || !routes.current(context) {
		return Err(Error::closed("the route opening has retired"));
	}
	if routes.live(context) {
		return Ok(());
	}
	let mut behavior = make.borrow_mut()(context.clone())?;
	if *stop.borrow() || !routes.current(context) {
		return Err(Error::closed("the reply factory retired its route opening"));
	}
	let (held, accepted) = (routes.clone(), context.clone());
	let direct = direct
		.with_behavior(Box::new(move |verb, args| {
			if !held.current(&accepted) {
				return Err(rooms_application::failure::Failure {
					code: rooms_application::failure::FailureCode::DirectNotAccepted,
					detail: "that exact direct conversation is no longer accepted",
				}
				.to_string());
			}
			behavior(verb, args)
		}))
		.map_err(Error::peer)?;
	routes.install(context, direct)?;
	Ok(())
}
