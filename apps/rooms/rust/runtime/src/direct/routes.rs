//! Reciprocal connection custody belongs to the session owner. Hosted inboxes
//! hold only an observer, so a route cannot retain its own publishing Host.
use crate::Error;
use crate::directories::runtime::AcceptedDirect;
use crate::directories::runtime::Platform;
use glowcap::{PendingWork, Ref, Session};
use rooms_glowcap::client::{Client, direct::Direct, posted_line::PostedLine};
use std::{
	cell::{Cell, RefCell},
	rc::{Rc, Weak},
};
use tokio::sync::watch;

#[derive(Clone)]
pub struct DirectRoutes<P: Platform>(Rc<State<P>>);
#[derive(Clone)]
pub struct RouteReceiver<P: Platform>(Weak<State<P>>);
struct State<P: Platform> {
	closed: Cell<bool>,
	rows: RefCell<Vec<Route<P>>>,
	retiring: RefCell<Vec<Retiring>>,
	changed: watch::Sender<()>,
}
struct Route<P: Platform> {
	context: AcceptedDirect,
	line: Rc<Direct<P>>,
}
struct Retiring {
	session: Session,
	reason: Retirement,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Retirement {
	IntentEnded,
	PartnerLeft,
}
impl Retirement {
	fn expected(self, kind: glowcap::ErrorKind, secondary_count: u32) -> bool {
		self == Self::PartnerLeft && kind == glowcap::ErrorKind::TimedOut && secondary_count == 0
	}
	fn close_result(self, result: Result<(), glowcap::Error>) -> Result<(), Error> {
		match result {
			Err(error) if self.expected(error.kind(), error.secondary_error_count()) => Ok(()),
			result => result.map_err(Error::from),
		}
	}
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum RouteSource {
	Opening,
	Reply,
}
#[derive(Debug, PartialEq, Eq)]
pub enum Adoption {
	Installed,
	Repeated,
	KeptLive,
}
fn owner_ended() -> Error {
	Error::closed("the direct route owner has ended")
}
impl<P: Platform> Default for DirectRoutes<P> {
	fn default() -> Self {
		Self::new()
	}
}
impl<P: Platform> DirectRoutes<P> {
	pub fn new() -> Self {
		Self(Rc::new(State {
			closed: Cell::new(false),
			rows: RefCell::new(Vec::new()),
			retiring: RefCell::new(Vec::new()),
			changed: watch::channel(()).0,
		}))
	}
	pub fn receiver(&self) -> RouteReceiver<P> {
		RouteReceiver(Rc::downgrade(&self.0))
	}
	/// Drive on committed intent changes. Admission checks retirement even if
	/// this cleanup has not yet run. Only this owner's occurrences are dropped.
	pub fn reconcile(&self) {
		self.0.reconcile();
	}
	pub fn close(&self) {
		self.0.closed.set(true);
		self.0.rows.borrow_mut().clear();
		self.0.changed.send_replace(());
	}
	pub fn live(&self, context: &AcceptedDirect) -> bool {
		self.route(context).is_ok()
	}
	/// A live route for this checkpoint conversation, if one is connected.
	pub fn conversation(&self, id: &str) -> Result<AcceptedDirect, Error> {
		self.reconcile();
		self.0
			.rows
			.borrow()
			.iter()
			.find(|row| row.context.conversation().text().as_str() == Some(id) && row.line.live())
			.map(|row| row.context.clone())
			.ok_or_else(|| Error::closed("that direct conversation is not connected in this Rooms session"))
	}
	pub fn changes(&self) -> watch::Receiver<()> {
		self.0.changed.subscribe()
	}
	fn route(&self, context: &AcceptedDirect) -> Result<Rc<Direct<P>>, Error> {
		self.reconcile();
		self.0.line(context)
	}
	/// Pending sends retain their admitted route without borrowing the registry
	/// across the await. A result arriving after retirement is released here.
	/// A returned delegated line has its own custody, independent of the route.
	/// Reciprocal send/typing after a route is live. The caller clones the line.
	pub fn live_line(&self, context: &AcceptedDirect) -> Result<Rc<Direct<P>>, Error> {
		self.route(context)
	}
	pub async fn say(&self, context: &AcceptedDirect, text: &str) -> Result<Option<PostedLine<P>>, Error> {
		let route = self.route(context)?;
		let result = route.say(text).await;
		self.0.require(context)?;
		result.map_err(Error::peer)
	}
	pub fn typing(&self, context: &AcceptedDirect, on: bool) -> Result<(), Error> {
		self.route(context)?.typing(on).map_err(Error::peer)
	}
}
impl<P: Platform> Drop for DirectRoutes<P> {
	fn drop(&mut self) {
		// Clones share one owner. Closing on every drop would shut the dispatcher
		// when a reply task only needed a route for one send.
		if Rc::strong_count(&self.0) == 1 {
			self.close();
		}
	}
}
impl<P: Platform> State<P> {
	/// Drop the routes whose conversation retired. Every route lookup runs
	/// this first, so the common case, nothing retired, must allocate nothing:
	/// `retain` keeps the rows in place and `retired` stays empty.
	fn reconcile(&self) {
		let mut rows = self.rows.borrow_mut();
		let mut retired = Vec::new();
		rows.retain(|row| {
			if row.context.current() {
				return true;
			}
			retired.push((
				row.line.clone(),
				if row.context.partner_left() {
					Retirement::PartnerLeft
				} else {
					Retirement::IntentEnded
				},
			));
			false
		});
		if retired.is_empty() {
			return;
		}
		{
			let mut retiring = self.retiring.borrow_mut();
			for (line, _) in &retired {
				// Every route on a connection must justify an expected close.
				let reason = if retired.iter().any(|(other, reason)| {
					other.session().same_session(line.session()) && *reason == Retirement::IntentEnded
				}) {
					Retirement::IntentEnded
				} else {
					Retirement::PartnerLeft
				};
				if let Some(held) = retiring
					.iter_mut()
					.find(|held| held.session.same_session(line.session()))
				{
					held.reason = reason;
				} else if line.owns_session() {
					retiring.push(Retiring {
						session: line.session().borrowed(),
						reason,
					});
				}
			}
		}
		drop(rows);
		self.changed.send_replace(());
	}
	fn line(&self, context: &AcceptedDirect) -> Result<Rc<Direct<P>>, Error> {
		self.require(context)?;
		self.rows
			.borrow()
			.iter()
			.find(|row| row.context.same_context(context) && row.line.live())
			.map(|row| row.line.clone())
			.ok_or_else(|| Error::closed("the direct conversation has no live route"))
	}
	fn require(&self, context: &AcceptedDirect) -> Result<(), Error> {
		if self.closed.get() || !context.current() {
			return Err(Error::closed("the direct route owner or conversation has retired"));
		}
		Ok(())
	}
}
impl<P: Platform> RouteReceiver<P> {
	/// Close exporter sessions whose last owning direct intent retired. A fresh
	/// sibling route installed before cleanup keeps the shared session alive.
	pub(super) async fn retire_sessions(&self) -> Result<(), Error> {
		let state = self.0.upgrade().ok_or_else(owner_ended)?;
		let mut result = Ok(());
		// Leave shared connections in custody until their last route retires.
		// Select each close immediately before awaiting it: earlier closes can
		// admit new routes or retirement evidence for the remaining sessions.
		let limit = state.retiring.borrow().len();
		for _ in 0..limit {
			let next = {
				let rows = state.rows.borrow();
				let mut retiring = state.retiring.borrow_mut();
				retiring
					.iter()
					.position(|held| !rows.iter().any(|row| row.line.session().same_session(&held.session)))
					.map(|index| retiring.remove(index))
			};
			let Some(Retiring { session, reason }) = next else {
				break;
			};
			let closed = reason.close_result(session.close(PendingWork::Cancel).await);
			result = Error::fold(result, closed);
		}
		result
	}
	pub(super) fn reconcile(&self) -> Result<(), Error> {
		let state = self.0.upgrade().ok_or_else(owner_ended)?;
		if state.closed.get() {
			return Err(Error::closed("the direct route owner has closed"));
		}
		state.reconcile();
		Ok(())
	}
	/// Consume the actual reply occurrence and delivering session. Redundant
	/// occurrences are released. A fresh reply occurrence is the peer's current
	/// route evidence, including after it reopens on another connection.
	pub fn adopt(&self, context: &AcceptedDirect, client: Client<P>, reply: Ref) -> Result<Adoption, Error> {
		self.install_route(
			context,
			Direct::adopt(client, reply, context.registration().clone()),
			RouteSource::Reply,
		)
	}
	pub(super) fn current(&self, context: &AcceptedDirect) -> bool {
		self.0.upgrade().is_some_and(|state| state.require(context).is_ok())
	}
	pub(super) fn live(&self, context: &AcceptedDirect) -> bool {
		self.line(context).is_ok()
	}
	pub(super) fn changes(&self) -> Result<watch::Receiver<()>, Error> {
		Ok(self.0.upgrade().ok_or_else(owner_ended)?.changed.subscribe())
	}
	pub fn line(&self, context: &AcceptedDirect) -> Result<Rc<Direct<P>>, Error> {
		let state = self.0.upgrade().ok_or_else(owner_ended)?;
		state.line(context)
	}
	pub(super) async fn announce(&self, context: &AcceptedDirect) -> Result<(), Error> {
		let line = self.line(context)?;
		let result = line.establish_reply_route().await.map_err(Error::peer);
		if !self.current(context) {
			return Err(Error::closed("the direct route has retired"));
		}
		result
	}
	pub(super) fn install(&self, context: &AcceptedDirect, incoming: Direct<P>) -> Result<Adoption, Error> {
		self.install_route(context, incoming, RouteSource::Opening)
	}
	fn install_route(
		&self,
		context: &AcceptedDirect,
		incoming: Direct<P>,
		source: RouteSource,
	) -> Result<Adoption, Error> {
		let state = self.0.upgrade().ok_or_else(owner_ended)?;
		state.require(context)?;
		if incoming.registration() != context.registration() {
			return Err(Error::stale("the route belongs to another registration"));
		}
		state.reconcile();
		let mut rows = state.rows.borrow_mut();
		let existing = rows.iter().position(|row| row.context.same_context(context));
		if let Some(index) = existing {
			let line = &rows[index].line;
			if line.same_route(&incoming) {
				return Ok(Adoption::Repeated);
			}
			// A concurrent outbound opening cannot replace an established route.
			// A peer's new reply capability can: its previous inbox may have
			// retired while that inbox's transport is still open.
			if source == RouteSource::Opening && line.live() {
				return Ok(Adoption::KeptLive);
			}
		}
		if !incoming.live() {
			return Err(Error::closed("the arriving direct route is no longer live"));
		}
		// Each accepted checkpoint bounds its conversations; this owner also
		// bounds aggregate custody when supplied contexts from multiple sessions.
		if existing.is_none() && rows.len() == rooms_application::direct::publication::DEFAULT_INBOX_LIMIT {
			return Err(Error::exhausted("the direct route owner is full"));
		}
		glowcap::annotate_session(incoming.session(), Some(context.peer_name()));
		let route = Route {
			context: context.clone(),
			line: Rc::new(incoming),
		};
		if let Some(index) = existing {
			let previous = &rows[index].line;
			if previous.owns_session() {
				let mut retiring = state.retiring.borrow_mut();
				if !retiring
					.iter()
					.any(|held| held.session.same_session(previous.session()))
				{
					retiring.push(Retiring {
						session: previous.session().borrowed(),
						reason: Retirement::IntentEnded,
					});
				}
			}
			rows[index] = route;
		} else {
			rows.push(route);
		}
		drop(rows);
		state.changed.send_replace(());
		Ok(Adoption::Installed)
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn only_a_departed_partners_unanswered_close_is_expected() {
		use glowcap::ErrorKind;
		assert!(Retirement::PartnerLeft.expected(ErrorKind::TimedOut, 0));
		assert!(!Retirement::IntentEnded.expected(ErrorKind::TimedOut, 0));
		assert!(!Retirement::PartnerLeft.expected(ErrorKind::Io, 0));
		assert!(!Retirement::PartnerLeft.expected(ErrorKind::Internal, 0));
		assert!(!Retirement::PartnerLeft.expected(ErrorKind::TimedOut, 1));
	}
}
