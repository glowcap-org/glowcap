//! Action-drain scheduling and terminal failure projection.

use super::*;

impl HostShared {
	pub(crate) fn record_background_failure(&self, error: Error) {
		let mut retained = self.background_failure.borrow_mut();
		*retained = Some(match retained.take() {
			Some(primary) => primary.with_secondary(error),
			None => error,
		});
		self.note_close_activity();
	}

	pub(crate) fn take_background_failure(&self) -> Option<Error> {
		self.background_failure.borrow_mut().take()
	}

	// ── The action drain (the one loop rule) ──────────────────────────────────

	/// Kick the action drain from a synchronous verb: schedule it as its own
	/// task on the `LocalSet`.
	pub(crate) fn schedule_kick(self: &Rc<HostShared>) -> Result<()> {
		// On a loop-adopted Host the native loop is the one drain, so the kick
		// becomes a scheduled loop step — deferred, so a kick from inside a
		// turn steps only after the enclosing step unwinds.
		if let Some(lp) = self.driver_loop() {
			lp.schedule_step();
			return lp.guard_handle();
		}
		if inside_turn() || self.raw.get().is_null() {
			return Ok(());
		}
		if self.closing() {
			// The close driver owns the drain while the barrier runs, so a
			// kick cannot spawn one; wake the driver instead, and the work
			// this verb queued drains in its next pass.
			self.note_close_activity();
			return Ok(());
		}
		let registration = self.start_owned_task()?;
		let host = Rc::clone(self);
		if !try_spawn_local(async move {
			let _registration = registration;
			if let Err(error) = host.kick_actions().await {
				let detail = format!("action drain failed: {error}");
				host.fail_pending_vows(error.code(), &detail);
				host.record_background_failure(error);
			}
		}) {
			return Err(Error::with_detail(
				sys::ERR_INTERNAL,
				"action progress requires a running LocalSet; queued work was not discarded".to_string(),
			));
		}
		Ok(())
	}

	/// Schedule progress for an unowned destructor/finalizer effect. The work
	/// stays queued, and refused admission is retained for the next verb head.
	pub(crate) fn schedule_kick_or_record(self: &Rc<HostShared>) {
		if let Err(error) = self.schedule_kick() {
			self.record_background_failure(error);
		}
	}

	/// Run the shared C action drain, then honor each parked arm. Reentrant on
	/// purpose, the async spelling of the Racket binding's reentrant host lock:
	/// the DIAL arm's dial executor establishes a whole new session *inside*
	/// an action, and that establish must itself drain (its start-session
	/// FLUSH) — a single-flighted drain would await its own completion there.
	/// Arms are parked under `pancake_host_pump_drain` (sync hooks only) and
	/// awaited after the C loop returns, so overlapping kickers never await
	/// inside the C callback. Re-parks until empty: a NEED_GIFT_ID's
	/// `provide_gift_id` can queue FLUSH legs after the C drain returns (same
	/// as Racket's `drain-host-actions!`). A no-op inside a hosted turn: the
	/// host refuses the driving verbs there, and everything the turn enqueued
	/// pumps when the enclosing feed unwinds into this same drain.
	pub(crate) async fn kick_actions(self: &Rc<HostShared>) -> Result<()> {
		if inside_turn() || self.raw.get().is_null() {
			return Ok(());
		}
		crate::finalizer::drain();
		crate::gc::drain(self)?;
		// The native loop is the drain on a loop-adopted Host: one step flushes
		// what a verb queued and routes completions as loop events. No
		// `pancake_host_pump_drain` may run beside it — the loop owns the queue.
		if let Some(lp) = self.driver_loop() {
			return match lp.step_now() {
				Ok(()) => Ok(()),
				Err(error) => {
					let surfaced = error.clone();
					lp.fail_background(error);
					Err(surfaced)
				}
			};
		}
		loop {
			if self.raw.get().is_null() {
				return Ok(());
			}
			// The native drain resumes queued Host work before its first
			// external action and may synchronously invoke a behavior.
			let (parked, yielded) = {
				let _deliver = crate::trampoline::DeliverGuard::enter_host(self);
				crate::action::park(self)?
			};
			if parked.is_empty() && !yielded {
				return Ok(());
			}
			let mut first_failure = None;
			for action in parked {
				// One failing action must not strand the rest of the drain: a
				// FLUSH to a session whose socket just died fails here while
				// the actions behind it belong to other, live sessions. The
				// failed session tears itself down through its own serve loop
				// (a DIAL failure is reported to the core inside the arm).
				if let Err(error) = crate::action::run(self, action).await {
					if first_failure.is_none() {
						first_failure = Some(error);
					}
				}
			}
			// This pass did work that can advance close-relevant state; wake
			// any parked close driver so it re-checks progress. An idle pass
			// returns above without signaling, which keeps two parked close
			// drivers from waking each other in an endless idle exchange.
			self.note_close_activity();
			if let Some(error) = first_failure {
				return Err(error);
			}
			if yielded {
				tokio::task::coop::consume_budget().await;
			}
		}
	}
}
