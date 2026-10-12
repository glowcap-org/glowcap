//! Private lifetime custody can only retire the exact returned name or seat.
use glowcap::{Argument, Host, Ref, Result, loam};
use std::{
	cell::{Cell, RefCell},
	future::Future,
	pin::Pin,
};
use tokio::sync::{Mutex, Notify};

#[cfg(test)]
mod tests;

enum Outcome {
	Unstarted,
	Pending,
	Absent,
	Ready(Ref),
	Unknown(glowcap::Error),
	Closed,
}
type Observation = Pin<Box<dyn Future<Output = Result<Argument>>>>;

/// One fixed Rc owner per supervised membership retains one exact raw
/// endpoint returned by its admitted effect. It is private, exposes no call or
/// reference accessor, and sends only argument-free `leave`. Public results
/// continue to use source-dependent facets. A boxed vow observation exists only
/// during retirement and survives interrupted waits. Terminal refusal keeps the
/// same target for idempotent retry. The membership registry bounds these owners
/// independently of transient executor jobs, so live seats do not fill receipts.
/// Direct workers retain no raw route here. They observe the exporter behind
/// their exact admitted access field, including a committed Loam dependent
/// facet. One borrowed Session shell shares the Host's existing connection.
/// Dropping it never closes the channel. Keeping the observer independent of
/// effect outcomes prevents a readiness acknowledgment from erasing lifetime
/// custody. The existing registry accounts for siblings before explicit close.
pub(in crate::session::managed) struct Owner {
	host: Host,
	outcome: RefCell<Outcome>,
	closing: Cell<bool>,
	observation: Mutex<Option<Observation>>,
	changed: Notify,
	lifetime: RefCell<Option<glowcap::Session>>,
}
impl Owner {
	pub(super) fn new(host: Host) -> Self {
		Self {
			host,
			outcome: RefCell::new(Outcome::Unstarted),
			closing: Cell::new(false),
			observation: Mutex::new(None),
			changed: Notify::new(),
			lifetime: RefCell::new(None),
		}
	}
	pub(in crate::session::managed) fn begin(&self) {
		*self.outcome.borrow_mut() = Outcome::Pending;
		self.changed.notify_waiters();
	}
	pub(in crate::session::managed) fn ready(&self, target: Ref) -> Result<()> {
		*self.lifetime.borrow_mut() = exporter(&self.host, &target)?;
		*self.outcome.borrow_mut() = Outcome::Ready(target);
		self.changed.notify_waiters();
		Ok(())
	}
	pub(in crate::session::managed) fn absent(&self) {
		*self.outcome.borrow_mut() = Outcome::Absent;
		self.changed.notify_waiters();
	}
	pub(in crate::session::managed) fn unknown(&self, error: glowcap::Error) {
		*self.outcome.borrow_mut() = Outcome::Unknown(error);
		self.changed.notify_waiters();
	}
	pub(in crate::session::managed) fn closing(&self) -> bool {
		self.closing.get()
	}
	pub(super) fn connection_lost(&self) -> bool {
		self.lifetime
			.borrow()
			.as_ref()
			.is_some_and(|session| !session.is_open())
	}
	pub(super) fn connection(&self) -> Option<glowcap::Session> {
		self.lifetime.borrow().as_ref().map(glowcap::Session::borrowed)
	}
	pub(super) fn begin_close(&self) {
		self.closing.set(true);
	}
	pub(in crate::session::managed) fn observe(&self, session: Option<glowcap::Session>) -> Result<()> {
		let Some(session) = session else { return Ok(()) };
		let mut lifetime = self.lifetime.borrow_mut();
		if let Some(previous) = lifetime.as_ref() {
			return if previous.same_connection(&session) {
				Ok(())
			} else {
				Err(loam::refusal("direct route exporter changed during active membership"))
			};
		}
		*lifetime = Some(session.borrowed());
		self.changed.notify_waiters();
		Ok(())
	}
	/// Names and seats are connection leases. The server withdraws them when
	/// their exporter connection ends, even if no final notification arrives.
	/// Local targets have no transport lifetime and wait for explicit retirement.
	pub(super) async fn ended(&self) -> Result<()> {
		let session = loop {
			let changed = self.changed.notified();
			tokio::pin!(changed);
			changed.as_mut().enable();
			if let Some(session) = self.connection() {
				break session;
			}
			changed.await;
		};
		let _terminal = session.ended().await;
		// Transport failure is affirmative loss of this connection lease,
		// independently of whether physical close itself succeeds.
		*self.outcome.borrow_mut() = Outcome::Closed;
		self.changed.notify_waiters();
		Ok(())
	}
	pub(in crate::session::managed) async fn close(&self) -> Result<()> {
		self.closing.set(true);
		if self
			.lifetime
			.borrow()
			.as_ref()
			.is_some_and(|session| !session.is_open())
		{
			*self.outcome.borrow_mut() = Outcome::Closed;
		}
		loop {
			let changed = self.changed.notified();
			tokio::pin!(changed);
			changed.as_mut().enable();
			let target = match &*self.outcome.borrow() {
				Outcome::Unstarted | Outcome::Absent | Outcome::Closed => return Ok(()),
				Outcome::Unknown(error) => return Err(error.clone()),
				Outcome::Pending => None,
				Outcome::Ready(target) => Some(target.clone()),
			};
			let Some(target) = target else {
				changed.await;
				continue;
			};
			let mut observation = self.observation.lock().await;
			if matches!(*self.outcome.borrow(), Outcome::Closed) {
				return Ok(());
			}
			let result = observation
				.get_or_insert_with(|| {
					let pending = self.host.send(&target, rooms_application::protocol_data::LEAVE, &[]);
					Box::pin(async move { pending.await })
				})
				.await;
			observation.take();
			if !matches!(result?, Argument::Void) {
				return Err(loam::refusal(
					"membership retirement returned an invalid acknowledgment",
				));
			}
			*self.outcome.borrow_mut() = Outcome::Closed;
			return Ok(());
		}
	}
}

/// Retain an observation view, never connection close authority. Host-retained
/// dials own the live channel. This fixed handle survives capability retirement.
pub(in crate::session::managed) fn exporter(host: &Host, target: &Ref) -> Result<Option<glowcap::Session>> {
	Ok(host.reference_session(target)?.map(|session| session.borrowed()))
}
