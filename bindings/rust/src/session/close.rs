use crate::execution::monotonic_ms;
use std::rc::Rc;

use super::Session;
use crate::host::{check_host, try_spawn_local_handle};
use crate::lifecycle::PendingWork;
use crate::session_shared::SessionShared;
use crate::sys;
use crate::sys::host as ffi;
use crate::{Error, Result};

impl Session {
	/// Compare views of the actual shared connection, independently of labels,
	/// locators, and whether either view owns its lifetime.
	pub fn same_connection(&self, other: &Session) -> bool {
		Rc::ptr_eq(&self.shared, &other.shared)
	}
	/// Sample native connection liveness without starting work or waiting for
	/// terminal cleanup. A closing Host or retired session returns false.
	pub fn is_open(&self) -> bool {
		self.shared.session_open()
	}

	/// Observe this session becoming unavailable for new work, without waiting
	/// for physical transport cleanup or native handle release. This is the
	/// asynchronous counterpart to [`Session::is_open`]: independent and late
	/// observers share the same transition, and cancelling one observer changes
	/// no session state.
	///
	/// Use [`Session::closed`] when ownership retirement itself is the outcome
	/// being reconciled. A connection can have ended while its close owner is
	/// still finishing a protocol shutdown or releasing platform resources.
	pub async fn ended(&self) -> Result<()> {
		wait_session_end(&self.shared).await;
		self.shared.terminal_result()
	}

	/// Observe terminal session retirement without requesting close or taking
	/// the serve task. Independent and late observers share the terminal result.
	/// Cancelling an observer leaves the connection and its other observers live.
	pub async fn closed(&self) -> Result<()> {
		wait_session_close(&self.shared).await;
		self.shared.terminal_result()
	}

	/// A session view whose lifetime does not keep the connection open. The
	/// owning handles or Host control retirement. Calls through this view then
	/// refuse normally. Explicit `close` still closes the named connection.
	pub fn borrowed(&self) -> Session {
		Session::view(Rc::clone(&self.shared))
	}

	/// Relinquish this handle, observing transport close only when it is the
	/// final owner of a connection the application owns. Host-retained dials and
	/// other application owners remain usable. A borrowed callback/redeem view
	/// relinquishes no close authority.
	pub async fn relinquish(self, pending: PendingWork) -> Result<()> {
		if self.owns_session && self.shared.owner_handles.get() == 1 && !self.shared.host_retained.get() {
			self.close(pending).await
		} else {
			Ok(())
		}
	}

	/// Close the session. A running [`serve`](Session::serve) completes. Pending
	/// vows settle closed.
	///
	/// This closes the connection it names and nothing else: not a sibling
	/// session, and not the connections the host dialed by itself to redeem a
	/// handoff: the `via` from [`send_redeeming`](Session::send_redeeming) is
	/// one of those. [`Host::close`](crate::Host::close) is what ends those.
	pub async fn close(&self, pending: PendingWork) -> Result<()> {
		if self.shared.released.get() {
			return self.shared.terminal_result();
		}
		request_session_close(&self.shared, pending)?;
		ensure_session_close_driver(&self.shared)?;
		wait_session_close(&self.shared).await;
		self.shared.terminal_result()
	}
}

fn ensure_session_close_driver(shared: &Rc<SessionShared>) -> Result<()> {
	if shared.close_task.borrow().is_some() {
		return Ok(());
	}
	let driver = Rc::clone(shared);
	let Some(task) = try_spawn_local_handle(async move { drive_session_close(driver).await }) else {
		return Err(Error::with_detail(
			sys::ERR_INTERNAL,
			"session close requires a running LocalSet".into(),
		));
	};
	*shared.close_task.borrow_mut() = Some(task);
	Ok(())
}

async fn drive_session_close(shared: Rc<SessionShared>) {
	while !shared.released.get() {
		#[cfg(not(target_arch = "wasm32"))]
		if let Some(loop_) = shared.loop_wire.as_ref() {
			// The loop tier's discipline: progress happens only inside
			// `glowcap_driver_step`, so this driver is the deadline-stepper.
			// Register the loop-activity waiter before stepping, so a rival
			// path's step landing between this step and the park still wakes
			// this driver instead of being lost.
			let notified = loop_.step_activity();
			tokio::pin!(notified);
			notified.as_mut().enable();
			if let Err(error) = loop_.step_now() {
				loop_.fail_background(error);
				return;
			}
			if shared.released.get() {
				break;
			}
			// Park on loop activity or on the nearest pending-work deadline
			// (this session's close grace included). An expiry takes effect
			// only inside a step, so the timer wake is what applies it; with
			// no finite deadline pending, readiness-driven steps alone
			// advance the loop.
			match loop_.step_wait() {
				Ok(Some(wait)) => {
					tokio::select! {
						() = notified.as_mut() => {}
						() = crate::execution::sleep(wait) => {}
					}
				}
				Ok(None) => notified.await,
				Err(error) => {
					shared.record_close_result(error.code());
					shared.close_transport();
					return;
				}
			}
			continue;
		}
		// Register the activity waiter before the progress check, so a verb
		// completing between the check and the await still wakes this loop
		// instead of being lost.
		let notified = shared.host.close_activity();
		tokio::pin!(notified);
		notified.as_mut().enable();
		let mut lifecycle = 0;
		// SAFETY: `shared.ptr` is this session's `GlowcapHostSession` handle, nulled only by `commit_native_release`,
		// which also sets `released`; no await separates this call from the `while !shared.released.get()` check at the
		// loop head, so the handle is live, and `lifecycle` is a local out-parameter the callee fills.
		let rc = unsafe { ffi::glowcap_host_session_close_progress(shared.ptr.get(), monotonic_ms(), &mut lifecycle) };
		if rc != sys::OK && rc != sys::ERR_TIMEOUT {
			shared.record_close_result(rc);
			shared.close_transport();
			return;
		}
		// Drain what progress queued (this session's release rides an action)
		// before parking; a productive drain re-signals the registered waiter.
		if let Err(error) = shared.host.kick_actions().await {
			shared.record_close_result(error.code());
			shared.close_transport();
			return;
		}
		if shared.released.get() {
			break;
		}
		// The host-level wait covers every session's FINISH grace deadline,
		// this one included; with no finite deadline pending, only host
		// activity can advance terminal progress.
		match shared.host.close_wait() {
			Ok(Some(wait)) => {
				tokio::select! {
					() = notified.as_mut() => {}
					() = crate::execution::sleep(wait) => {}
				}
			}
			Ok(None) => notified.await,
			Err(error) => {
				shared.record_close_result(error.code());
				shared.close_transport();
				return;
			}
		}
	}
}

async fn wait_session_close(shared: &SessionShared) {
	while !shared.released.get() {
		let notified = shared.closed.notified();
		tokio::pin!(notified);
		notified.as_mut().enable();
		if shared.released.get() {
			break;
		}
		notified.await;
	}
}

async fn wait_session_end(shared: &SessionShared) {
	while shared.session_open() {
		let notified = shared.closed.notified();
		tokio::pin!(notified);
		notified.as_mut().enable();
		if !shared.session_open() {
			break;
		}
		notified.await;
	}
}

pub(crate) fn session_close_result(code: i32) -> Result<()> {
	if code == sys::OK {
		Ok(())
	} else if code == sys::ERR_TIMEOUT {
		Err(Error::with_detail(
			code,
			"finish close exhausted its grace period".into(),
		))
	} else {
		Err(Error::with_detail(code, "native session close failed".into()))
	}
}

impl Drop for Session {
	fn drop(&mut self) {
		// Focused lifecycle tests use a borrowed handle while dropping the real
		// owner from inside its callback.
		if !self.owns_session {
			return;
		}
		let owners = self.shared.owner_handles.get();
		debug_assert!(owners != 0);
		self.shared.owner_handles.set(owners - 1);
		if owners != 1 || self.shared.released.get() || self.shared.host_retained.get() {
			return;
		}
		// A drop has no result channel. Inside a behavior callback the native
		// close is refused, and `close_transport` parks the release
		// for the next drain, as the Host's own drop does.
		if crate::trampoline::inside_turn() {
			self.shared.close_transport();
			return;
		}
		// Anywhere else, an owned session's close request is refused only by
		// the loop's own terminal failure or by a missing LocalSet, and the
		// fallback records exactly those: the loop retains the first, and
		// `close_transport` records the second through its kick. Retaining the
		// refusal here too would be the same cause twice, so it is not.
		if request_session_close(&self.shared, PendingWork::Cancel)
			.and_then(|()| ensure_session_close_driver(&self.shared))
			.is_err()
		{
			self.shared.close_transport();
		}
	}
}

fn request_session_close(shared: &Rc<SessionShared>, pending: PendingWork) -> Result<()> {
	if shared.released.get() {
		return Ok(());
	}
	request_close_on_owner(shared, pending)?;
	shared.closing.set(true);
	Ok(())
}

fn request_close_on_owner(shared: &Rc<SessionShared>, pending: PendingWork) -> Result<()> {
	#[cfg(not(target_arch = "wasm32"))]
	if let Some(loop_) = shared.loop_wire.as_ref() {
		return loop_.request_session_close(shared.ptr.get(), pending);
	}
	let options = pending.to_ffi()?;
	// SAFETY: `shared.ptr` is this session's `GlowcapHostSession` handle, live because `request_session_close` checked
	// `released` just before calling here; `options` is a local `GlowcapCloseOptions` borrowed for the call and read
	// only during it.
	check_host(unsafe { ffi::glowcap_host_session_close(shared.ptr.get(), &options, monotonic_ms()) })?;
	// A close request or escalation is close-relevant activity: a driver
	// parked on a now-superseded wait must re-check progress.
	shared.host.note_close_activity();
	shared.host.schedule_kick()?;
	Ok(())
}
