//! Loop stepping, event dispatch, dial, and listener admission.

use super::*;

impl LoopShared {
	/// Drain zero-timeout steps through quiescence and dispatch their events,
	/// on the loop thread. Reaching WOULD_BLOCK is what permits an
	/// edge-triggered readiness guard to clear without losing a sibling source.
	pub(crate) fn step_now(self: &Rc<Self>) -> Result<()> {
		if self.released.get() || self.stepping.get() || crate::trampoline::inside_turn() {
			return Ok(());
		}
		let mut stepped = false;
		loop {
			let outcome = {
				self.stepping.set(true);
				let host = self.wrapper.borrow().as_ref().and_then(Weak::upgrade);
				// The head of the byte-fed kick, one tier up: run parked releases
				// and reclaimed-import releases before the step, so a dropped
				// `Ref`'s op:gc-exports flushes in the very step this kick runs.
				crate::finalizer::drain();
				let gc_result = host.as_ref().map_or(Ok(()), |host| crate::gc::drain(host));
				let result = match gc_result {
					Ok(()) => {
						// The step is the deliver: behaviors fire inside it, and the
						// bracket latches their turns to this loop's wrapper Host.
						let _bracket = host.as_ref().map(DeliverGuard::enter_host);
						self.driver.step(0)
					}
					Err(error) => Err(error),
				};
				self.stepping.set(false);
				result
			};
			crate::finalizer::drain();
			match outcome {
				Ok(Some(events)) => {
					stepped = true;
					if !events.is_empty() {
						self.dispatch(events);
					}
				}
				Ok(None) => break,
				Err(error) => return Err(error),
			}
		}
		// A pass that ran at least one native step advanced state a close
		// driver may be parked on. An idle pass stays silent, which keeps a
		// parked driver's own quiescent re-step from waking itself in an
		// endless exchange.
		if stepped {
			self.note_step_activity();
		}
		Ok(())
	}

	pub(super) fn dispatch(self: &Rc<Self>, events: Vec<LoopEvent>) {
		let host = self.wrapper.borrow().as_ref().and_then(Weak::upgrade);
		for event in events {
			match event {
				LoopEvent::Opened { operation_id, session } => {
					if let Some(waiter) = self.pending_dials.borrow_mut().remove(&operation_id) {
						self.unclaimed_sessions
							.borrow_mut()
							.insert(session as usize, UnclaimedSession::Open);
						if waiter.send(Ok(session)).is_err() {
							self.release_unclaimed_session(session);
						}
					} else {
						self.unclaimed_sessions
							.borrow_mut()
							.insert(session as usize, UnclaimedSession::Open);
						self.release_unclaimed_session(session);
					}
				}
				LoopEvent::OpenFailed { operation_id, failure } => {
					if let Some(waiter) = self.pending_dials.borrow_mut().remove(&operation_id) {
						// Failure has no associated native session. If the receiver went
						// away, cancellation is its terminal observation.
						drop(waiter.send(Err(driver_event_failure(failure, "dial"))));
					}
				}
				LoopEvent::ListenerReady { listener } => {
					let Some(waiter) = self.pending_listeners.borrow_mut().remove(&listener) else {
						if let Err(error) = self.driver.close_listener(listener) {
							self.fail_background(error);
							return;
						}
						continue;
					};
					self.listeners.borrow_mut().insert(listener);
					if waiter.send(Ok(())).is_err() {
						self.listeners.borrow_mut().remove(&listener);
						if let Err(error) = self.driver.close_listener(listener) {
							self.fail_background(error);
							return;
						}
					}
				}
				LoopEvent::ListenerFailed { listener, failure } => {
					let error = driver_event_failure(failure, "listener");
					if let Some(waiter) = self.pending_listeners.borrow_mut().remove(&listener) {
						// Native listener setup already terminated; a dropped receiver is
						// therefore caller cancellation, with no cleanup left to lose.
						drop(waiter.send(Err(error)));
					} else if self.listeners.borrow_mut().remove(&listener) {
						self.listener_failures.borrow_mut().insert(listener, error);
						self.accept_wake.notify_waiters();
					}
				}
				LoopEvent::Accepted { listener, session } => {
					if !self.listeners.borrow().contains(&listener) {
						self.unclaimed_sessions
							.borrow_mut()
							.insert(session as usize, UnclaimedSession::Open);
						self.release_unclaimed_session(session);
						self.fail_background(Error::with_detail(
							sys::ERR_INTERNAL,
							format!("accepted session names unknown listener {listener}"),
						));
						return;
					}
					self.unclaimed_sessions
						.borrow_mut()
						.insert(session as usize, UnclaimedSession::Open);
					self.accepts.borrow_mut().push_back((listener, session));
					self.accept_wake.notify_waiters();
				}
				LoopEvent::SessionClosed { session, failure } => {
					// The pump's EOF choreography, one tier up: record local
					// teardown, then retire the shell so a later verb refuses
					// ERR_CLOSED. The native side already broke the far vows
					// and classified their FAIL completions.
					let shell = host
						.as_ref()
						.and_then(|host| host.sessions.borrow().get(&(session as usize)).cloned());
					if let Some(shell) = shell {
						let close_result = self
							.driver
							.session_lifecycle_state(session)
							.map(|(_, code)| code)
							.unwrap_or_else(|error| error.code());
						if let Some(failure) = failure.clone() {
							shell.record_wire_failure(driver_event_failure(failure, "session"));
						}
						shell.closing.set(true);
						shell.record_close_result(close_result);
						shell.close_transport();
					} else if let Some(state) = self.unclaimed_sessions.borrow_mut().get_mut(&(session as usize)) {
						*state =
							UnclaimedSession::Closed(failure.map(|failure| driver_event_failure(failure, "session")));
					} else {
						// A loop-internal session that no application outcome can
						// still claim is dead; retire its native handle now.
						self.unclaimed_sessions
							.borrow_mut()
							.insert(session as usize, UnclaimedSession::Closed(None));
						self.release_unclaimed_session(session);
					}
				}
				LoopEvent::Completion(action) => {
					let Some(host) = host.as_ref() else { continue };
					match action {
						HostAction::Settle { ticket, value } => {
							host.settle_vow(ticket, Ok(value));
						}
						HostAction::Fail {
							ticket,
							result,
							message,
						} => {
							host.settle_vow(ticket, Err(Error::with_detail(result, message)));
						}
						// FLUSH/CLOSE/DIAL/NEED_GIFT_ID never surface: the
						// loop executes transport-shaped actions internally.
						_ => {}
					}
				}
			}
		}
		crate::finalizer::drain();
		// Dispatch runs only with events in hand, so it always advanced state
		// a close driver may be parked on (a released session, a settled vow,
		// a retired listener). The direct dispatch callers (listener close's
		// preserve-committed drain) reach waiters through this same signal.
		self.note_step_activity();
	}

	/// Begin a nonblocking dial and await its session handle. The handshake advances
	/// across steps (`driver.HostRuntime.startDial`), so loops on one
	/// thread can dial each other and a stalled partner costs its budget,
	/// never the loop.
	pub(crate) async fn dial_locator(
		self: &Rc<Self>,
		locator: &Locator,
		options: Option<&[u8]>,
	) -> Result<*mut ffi_host::PancakeHostSession> {
		self.guard_handle()?;
		self.ensure_started()?;
		let operation_id = self.driver.dial(locator, options)?;
		let (waiter, outcome) = oneshot::channel();
		self.pending_dials.borrow_mut().insert(operation_id, waiter);
		// The park task may have read "no deadline" before this operation was
		// admitted. Make it rebuild its native-authoritative progress clock.
		self.note_step_activity();
		self.schedule_step();
		match outcome.await {
			Ok(outcome) => outcome,
			Err(_) => Err(loop_closed_error()),
		}
	}

	/// Await the next accepted session handle (bind a listener first). Fails
	/// with the typed `ERR_CLOSED` once the loop closes, so a server
	/// iteration ends rather than parking forever.
	#[cfg(any(feature = "tcp", feature = "iroh", feature = "onion"))]
	pub(crate) async fn accept(self: &Rc<Self>, listener: u64) -> Result<*mut ffi_host::PancakeHostSession> {
		loop {
			let notified = self.accept_wake.notified();
			tokio::pin!(notified);
			notified.as_mut().enable();
			let position = self
				.accepts
				.borrow()
				.iter()
				.position(|(accepted_by, _)| *accepted_by == listener);
			if let Some(position) = position {
				return Ok(self.accepts.borrow_mut().remove(position).unwrap().1);
			}
			if self.released.get() || !self.listeners.borrow().contains(&listener) {
				if let Some(error) = self.listener_failures.borrow().get(&listener) {
					return Err(error.clone());
				}
				return Err(loop_closed_error());
			}
			notified.await;
		}
	}

	/// Bind one listener on an added transport; accepted sessions arrive
	/// through [`LoopShared::accept`].
	#[cfg(any(feature = "tcp", feature = "iroh", feature = "onion"))]
	pub(crate) async fn listen(self: &Rc<Self>, transport: &str, designator: &str) -> Result<u64> {
		self.guard_handle()?;
		self.ensure_started()?;
		let listener = self.driver.listen(transport, designator)?;
		let (waiter, outcome) = oneshot::channel();
		self.pending_listeners.borrow_mut().insert(listener, waiter);
		let mut pending = PendingListenerSetup {
			lp: Rc::clone(self),
			listener,
			armed: true,
		};
		// Pending provider setup can install a finite listener deadline without
		// descriptor readiness. Re-arm the park task from the driver's clock.
		self.note_step_activity();
		self.schedule_step();
		let result = match outcome.await {
			Ok(result) => result,
			Err(_) => Err(loop_closed_error()),
		};
		pending.armed = false;
		result.map(|()| listener)
	}
}
