//! Reciprocal connection custody belongs to the session owner. Hosted inboxes
//! hold only an observer, so a route cannot retain its own publishing Host.
use crate::directory_runtime::AcceptedDirect;
use crate::directory_runtime::Platform;
use glowcap::{PendingWork, Ref, Session};
use rooms_glowcap::client::{direct::Direct, posted_line::PostedLine, Client};
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
	retiring: RefCell<Vec<Session>>,
	changed: watch::Sender<()>,
}
struct Route<P: Platform> {
	context: AcceptedDirect,
	line: Rc<Direct<P>>,
}
#[derive(Debug, PartialEq, Eq)]
pub enum Adoption {
	Installed,
	Repeated,
	KeptLive,
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
	pub fn conversation(&self, id: &str) -> Result<AcceptedDirect, String> {
		self.reconcile();
		self.0
			.rows
			.borrow()
			.iter()
			.find(|row| row.context.conversation().text().as_str() == Some(id) && row.line.live())
			.map(|row| row.context.clone())
			.ok_or_else(|| "that direct conversation is not connected in this Rooms session".into())
	}
	pub fn changes(&self) -> watch::Receiver<()> {
		self.0.changed.subscribe()
	}
	fn route(&self, context: &AcceptedDirect) -> Result<Rc<Direct<P>>, String> {
		self.reconcile();
		self.0.line(context)
	}
	/// Pending sends retain their admitted route without borrowing the registry
	/// across the await. A result arriving after retirement is released here.
	/// A returned delegated line has its own custody, independent of the route.
	/// Reciprocal send/typing after a route is live. The caller clones the line.
	pub fn live_line(&self, context: &AcceptedDirect) -> Result<Rc<Direct<P>>, String> {
		self.route(context)
	}
	pub async fn say(&self, context: &AcceptedDirect, text: &str) -> Result<Option<PostedLine<P>>, String> {
		let route = self.route(context)?;
		let result = route.say(text).await;
		self.0.require(context)?;
		result.map_err(|e| e.to_string())
	}
	pub fn typing(&self, context: &AcceptedDirect, on: bool) -> Result<(), String> {
		self.route(context)?.typing(on).map_err(|e| e.to_string())
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
	fn reconcile(&self) {
		let mut rows = self.rows.borrow_mut();
		let mut retired = Vec::new();
		let mut current = Vec::with_capacity(rows.len());
		for row in rows.drain(..) {
			if row.context.current() {
				current.push(row);
			} else {
				retired.push(row);
			}
		}
		*rows = current;
		let changed = !retired.is_empty();
		if changed {
			let mut retiring = self.retiring.borrow_mut();
			for row in &retired {
				if !row.line.owns_session()
					|| rows
						.iter()
						.any(|held| held.line.session().same_session(row.line.session()))
					|| retiring.iter().any(|session| session.same_session(row.line.session()))
				{
					continue;
				}
				retiring.push(row.line.session().borrowed());
			}
		}
		drop(rows);
		if changed {
			self.changed.send_replace(());
		}
	}
	fn line(&self, context: &AcceptedDirect) -> Result<Rc<Direct<P>>, String> {
		self.require(context)?;
		self.rows
			.borrow()
			.iter()
			.find(|row| row.context.same_context(context) && row.line.live())
			.map(|row| row.line.clone())
			.ok_or_else(|| "the direct conversation has no live route".into())
	}
	fn require(&self, context: &AcceptedDirect) -> Result<(), String> {
		if self.closed.get() || !context.current() {
			return Err("the direct route owner or conversation has retired".into());
		}
		Ok(())
	}
}
impl<P: Platform> RouteReceiver<P> {
	/// Close exporter sessions whose last owning direct intent retired. A fresh
	/// sibling route installed before cleanup keeps the shared session alive.
	pub(super) async fn retire_sessions(&self) -> Result<(), String> {
		let state = self.0.upgrade().ok_or("the direct route owner has ended")?;
		let sessions = core::mem::take(&mut *state.retiring.borrow_mut());
		let mut result = Ok(());
		for session in sessions {
			if state
				.rows
				.borrow()
				.iter()
				.any(|row| row.line.owns_session() && row.line.session().same_session(&session))
			{
				continue;
			}
			crate::cleanup::retain(
				&mut result,
				session
					.close(PendingWork::Cancel)
					.await
					.map_err(|error| error.to_string()),
			);
		}
		result
	}
	pub(super) fn reconcile(&self) -> Result<(), String> {
		let state = self.0.upgrade().ok_or("the direct route owner has ended")?;
		if state.closed.get() {
			return Err("the direct route owner has closed".into());
		}
		state.reconcile();
		Ok(())
	}
	/// Consume the actual reply occurrence and delivering session. Redundant
	/// occurrences are released; a different connection never displaces a live
	/// route. Names and partner keys cannot establish connection identity.
	pub fn adopt(&self, context: &AcceptedDirect, client: Client<P>, reply: Ref) -> Result<Adoption, String> {
		self.install(context, Direct::adopt(client, reply, context.registration().clone()))
	}
	pub(super) fn current(&self, context: &AcceptedDirect) -> bool {
		self.0.upgrade().is_some_and(|state| state.require(context).is_ok())
	}
	pub(super) fn live(&self, context: &AcceptedDirect) -> bool {
		self.line(context).is_ok()
	}
	pub(super) fn changes(&self) -> Result<watch::Receiver<()>, String> {
		Ok(self
			.0
			.upgrade()
			.ok_or("the direct route owner has ended")?
			.changed
			.subscribe())
	}
	pub fn line(&self, context: &AcceptedDirect) -> Result<Rc<Direct<P>>, String> {
		let state = self.0.upgrade().ok_or("the direct route owner has ended")?;
		state.line(context)
	}
	pub(super) async fn announce(&self, context: &AcceptedDirect) -> Result<(), String> {
		let line = self.line(context)?;
		let result = line.establish_reply_route().await.map_err(|e| e.to_string());
		if !self.current(context) {
			return Err("the direct route has retired".into());
		}
		result
	}
	pub(super) fn install(&self, context: &AcceptedDirect, incoming: Direct<P>) -> Result<Adoption, String> {
		let state = self.0.upgrade().ok_or("the direct route owner has ended")?;
		state.require(context)?;
		if incoming.registration() != context.registration() {
			return Err("the route belongs to another registration".into());
		}
		let mut rows = state.rows.borrow_mut();
		rows.retain(|row| row.context.current());
		let existing = rows.iter().position(|row| row.context.same_context(context));
		if let Some(index) = existing {
			let line = &rows[index].line;
			if line.same_route(&incoming) {
				return Ok(Adoption::Repeated);
			}
			// A partner can close and reopen its side while this local context and
			// pooled transport remain live. A fresh capability on that same session
			// is therefore the new route; another session cannot displace this one.
			if line.live() && !line.session().same_session(incoming.session()) {
				return Ok(Adoption::KeptLive);
			}
		}
		if !incoming.live() {
			return Err("the arriving direct route is no longer live".into());
		}
		// Each accepted checkpoint bounds its conversations; this owner also
		// bounds aggregate custody when supplied contexts from multiple sessions.
		if existing.is_none() && rows.len() == rooms_application::direct::publication::DEFAULT_INBOX_LIMIT {
			return Err("the direct route owner is full".into());
		}
		glowcap::annotate_session(incoming.session(), context.peer().text().as_str());
		let route = Route {
			context: context.clone(),
			line: Rc::new(incoming),
		};
		if let Some(index) = existing {
			rows[index] = route;
		} else {
			rows.push(route);
		}
		drop(rows);
		state.changed.send_replace(());
		Ok(Adoption::Installed)
	}
}
