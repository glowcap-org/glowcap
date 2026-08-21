use std::rc::Rc;

use super::Session;
use crate::host::{check_host, try_spawn_local_handle};
use crate::lifecycle::PendingWork;
use crate::session_shared::SessionShared;
use crate::sys;
use crate::sys::host as ffi;
use crate::{Error, Result};

impl Session {
	/// Close the session. A running [`serve`](Session::serve) completes; pending
	/// vows settle closed.
	///
	/// This closes the connection it names and nothing else: not a sibling
	/// session, and not the connections the host dialed by itself to redeem a
	/// handoff — the `via` from [`send_redeeming`](Session::send_redeeming) is
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
		if let Some(loop_) = shared.loop_wire.as_ref() {
			// The loop tier's discipline: progress happens only inside
			// `pancake_driver_step`, so this driver is the deadline-stepper.
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
						() = tokio::time::sleep(wait) => {}
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
		let rc = unsafe { ffi::pancake_host_session_close_progress(shared.ptr.get(), monotonic_ms(), &mut lifecycle) };
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
					() = tokio::time::sleep(wait) => {}
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

fn monotonic_ms() -> i64 {
	use std::sync::OnceLock;
	use std::time::Instant;

	static EPOCH: OnceLock<Instant> = OnceLock::new();
	let elapsed = EPOCH.get_or_init(Instant::now).elapsed().as_millis();
	i64::try_from(elapsed).unwrap_or(i64::MAX)
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
		if owners != 1 || self.shared.released.get() {
			return;
		}
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
	if let Some(loop_) = shared.loop_wire.as_ref() {
		loop_.request_session_close(shared.ptr.get(), pending)?;
	} else {
		let options = pending.to_ffi()?;
		check_host(unsafe { ffi::pancake_host_session_close(shared.ptr.get(), &options, monotonic_ms()) })?;
		// A close request or escalation is close-relevant activity: a driver
		// parked on a now-superseded wait must re-check progress.
		shared.host.note_close_activity();
		shared.host.schedule_kick()?;
	}
	shared.closing.set(true);
	Ok(())
}
