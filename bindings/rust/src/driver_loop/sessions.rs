//! Listener metadata, retirement, and session-handle transfer.

use super::*;

impl LoopShared {
	/// The listener's complete canonical OCapN locator.
	#[cfg(any(feature = "tcp", feature = "iroh", feature = "onion"))]
	pub(crate) fn listener_locator(&self, listener: u64) -> Result<Locator> {
		self.guard_handle()?;
		self.driver.listener_locator(listener)
	}

	#[cfg(feature = "onion")]
	pub(crate) fn listener_restoration_state(&self, listener: u64) -> Result<Vec<u8>> {
		self.guard_handle()?;
		self.driver.listener_restoration_state(listener)
	}

	#[cfg(feature = "tcp")]
	pub(crate) fn advertise_listener(&self, listener: u64, locator_uri: &str) -> Result<()> {
		self.guard_handle()?;
		let locator = crate::uri::parse_locator(locator_uri)?;
		self.driver.advertise_listener(listener, &locator)
	}

	#[cfg(any(feature = "tcp", feature = "iroh", feature = "onion"))]
	pub(crate) fn select_listener(&self, listener: u64) -> Result<()> {
		self.guard_handle()?;
		self.driver.select_listener(listener)
	}

	/// Stop one listener while keeping the loop and yielded sessions alive.
	/// Provider teardown may span steps; the returned future joins that native
	/// barrier and preserves its exact asynchronous failure.
	#[cfg(any(feature = "tcp", feature = "iroh", feature = "onion"))]
	pub(crate) async fn close_listener(self: &Rc<Self>, listener: u64) -> Result<()> {
		self.begin_listener_close(listener)?;
		loop {
			let notified = self.accept_wake.notified();
			tokio::pin!(notified);
			notified.as_mut().enable();
			if let Some(error) = self.terminal_failure.borrow().clone() {
				return Err(error);
			}
			if self.released.get() {
				return Ok(());
			}
			if let Some(error) = self.listener_failures.borrow_mut().remove(&listener) {
				return Err(error);
			}
			if !self.listeners.borrow().contains(&listener) && !self.closing_listeners.borrow().contains(&listener) {
				return Ok(());
			}
			self.schedule_step();
			notified.await;
		}
	}

	pub(crate) fn begin_listener_close(self: &Rc<Self>, listener: u64) -> Result<()> {
		self.guard_handle()?;
		if self.closing_listeners.borrow().contains(&listener) {
			return Ok(());
		}
		if !self.listeners.borrow().contains(&listener) {
			if let Some(error) = self.listener_failures.borrow().get(&listener) {
				return Err(error.clone());
			}
			return Ok(());
		}
		let closed = self.driver.close_listener(listener)?;
		let events = self.driver.drain_events()?;
		if !events.is_empty() {
			self.dispatch(events);
		}
		if closed {
			self.finish_listener_close(listener);
		} else {
			self.closing_listeners.borrow_mut().insert(listener);
			self.note_step_activity();
			self.schedule_step();
		}
		Ok(())
	}

	pub(super) fn advance_closing_listeners(self: &Rc<Self>) {
		let closing: Vec<u64> = self.closing_listeners.borrow().iter().copied().collect();
		for listener in closing {
			match self.driver.close_listener(listener) {
				Ok(true) => self.finish_listener_close(listener),
				Ok(false) => {}
				Err(error) => {
					self.closing_listeners.borrow_mut().remove(&listener);
					self.listeners.borrow_mut().remove(&listener);
					self.discard_accepts(listener);
					self.listener_failures.borrow_mut().insert(listener, error);
					self.accept_wake.notify_waiters();
				}
			}
		}
	}

	fn finish_listener_close(&self, listener: u64) {
		self.closing_listeners.borrow_mut().remove(&listener);
		self.listeners.borrow_mut().remove(&listener);
		self.discard_accepts(listener);
		self.accept_wake.notify_waiters();
	}

	/// A dropped setup future may race a committed READY event. Remove its
	/// waiter before draining native events, then retire either the still-pending
	/// or newly-active binding state without exposing a listener to the caller.
	#[cfg(any(feature = "tcp", feature = "iroh", feature = "onion"))]
	pub(super) fn cancel_listener_setup(self: &Rc<Self>, listener: u64) {
		self.pending_listeners.borrow_mut().remove(&listener);
		if self.released.get() {
			return;
		}
		self.listeners.borrow_mut().insert(listener);
		if let Err(error) = self.begin_listener_close(listener) {
			self.fail_background(error);
		}
	}

	/// Release accepted sessions that a closing server never yielded. The
	/// native listener-close contract preserves committed events; the public
	/// server contract transfers only sessions returned by `accept`.
	pub(crate) fn discard_accepts(&self, listener: u64) {
		let queued = self.accepts.borrow().len();
		for _ in 0..queued {
			let Some((accepted_by, session)) = self.accepts.borrow_mut().pop_front() else {
				break;
			};
			if accepted_by == listener {
				self.release_unclaimed_session(session);
			} else {
				self.accepts.borrow_mut().push_back((accepted_by, session));
			}
		}
	}

	/// Transfer one event-delivered handle into a binding Session, preserving a
	/// terminal event that committed before the wrapper existed.
	fn claim_session(&self, session: *mut ffi_host::PancakeHostSession) -> UnclaimedSession {
		self.unclaimed_sessions
			.borrow_mut()
			.remove(&(session as usize))
			.unwrap_or(UnclaimedSession::Open)
	}

	/// Release a handle the binding never transferred to an application. The
	/// loop remains its owner on refusal, so tracking is removed only after the
	/// native release commits.
	pub(super) fn release_unclaimed_session(&self, session: *mut ffi_host::PancakeHostSession) {
		if self.native_session_release(session).is_ok() {
			self.unclaimed_sessions.borrow_mut().remove(&(session as usize));
		}
	}

	pub(crate) fn claim_reference_exporter(
		&self,
		reference: &sys::PancakeReference,
	) -> Result<Option<*mut ffi_host::PancakeHostSession>> {
		self.driver.claim_reference_exporter(reference)
	}

	/// Release one loop-owned session through the loop's own verb, which also
	/// drops queued events naming it. A no-op once the loop is released: the
	/// loop's release freed its sessions itself.
	pub(crate) fn native_session_release(&self, session: *mut ffi_host::PancakeHostSession) -> Result<()> {
		if self.released.get() {
			return Ok(());
		}
		self.driver.session_release(session)
	}
}
/// Wrap a loop-minted session handle as the public [`Session`], over the
/// adopted wrapper Host: every session verb, promise, and trampoline works on
/// it, with the native loop as the transport and the drain.
pub(crate) fn loop_session(lp: &Rc<LoopShared>, session: *mut ffi_host::PancakeHostSession) -> Result<Session> {
	let host = lp.wrapper_host()?;
	let shared = SessionShared::new_loop(session, host, Rc::clone(lp));
	shared.spawn_serve();
	if let UnclaimedSession::Closed(failure) = lp.claim_session(session) {
		if let Some(failure) = failure {
			shared.record_wire_failure(failure);
		}
		shared.closing.set(true);
		shared.close_transport();
	}
	Ok(Session::owning(shared))
}
