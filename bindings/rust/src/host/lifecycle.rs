//! Host close barriers, owned-task lifetime, and terminal native retirement.

use super::*;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum CloseBarrierState {
	Idle,
	Running,
	Complete(i32),
	Failed,
}

/// Removes a detached DIAL task from its Host on every terminal path, including
/// panic and cancellation. It carries only a Weak owner, so task tracking never
/// creates a Host -> task -> Host retention cycle.
pub(crate) struct OwnedTaskRegistration {
	host: Weak<HostShared>,
}

impl Drop for OwnedTaskRegistration {
	fn drop(&mut self) {
		if let Some(host) = self.host.upgrade() {
			host.owned_task_finished();
		}
	}
}

struct DialTaskRegistration {
	host: Weak<HostShared>,
	attempt: (u64, usize),
	_owned: OwnedTaskRegistration,
}

struct AbortTaskOnDrop(Option<tokio::task::JoinHandle<()>>);

impl Drop for AbortTaskOnDrop {
	fn drop(&mut self) {
		if let Some(task) = self.0.take() {
			task.abort();
		}
	}
}

impl Drop for DialTaskRegistration {
	fn drop(&mut self) {
		if let Some(host) = self.host.upgrade() {
			host.dial_tasks.borrow_mut().remove(&self.attempt);
		}
	}
}

impl HostShared {
	pub(crate) fn closing(&self) -> bool {
		self.close_barrier.get() != CloseBarrierState::Idle
	}

	pub(crate) fn fail_close(&self, error: Error) {
		if matches!(
			self.close_barrier.get(),
			CloseBarrierState::Complete(_) | CloseBarrierState::Failed
		) {
			return;
		}
		*self.close_failure.borrow_mut() = Some(error);
		self.close_barrier.set(CloseBarrierState::Failed);
		self.release_notify.notify_waiters();
	}

	fn retained_close_failure(&self) -> Error {
		self.close_failure.borrow().clone().unwrap_or_else(|| {
			Error::with_detail(
				sys::ERR_INTERNAL,
				"host close failed without retaining its cause".to_string(),
			)
		})
	}

	pub(crate) fn native_close_committed(&self) {
		if self.close_barrier.get() == CloseBarrierState::Idle {
			self.close_barrier.set(CloseBarrierState::Running);
		}
	}

	/// Wake every close driver parked on host activity. Call it after any
	/// native verb that can advance close-relevant state; waiters re-check
	/// progress on every wake, so a spare signal costs one check and a missed
	/// one is a hang.
	pub(crate) fn note_close_activity(&self) {
		self.activity.notify_waiters();
	}

	/// The registration half of a close driver's wait. The returned future
	/// must be pinned and enabled before the close-progress check it guards,
	/// so a signal landing between that check and the await still wakes the
	/// driver.
	pub(crate) fn close_activity(&self) -> tokio::sync::futures::Notified<'_> {
		self.activity.notified()
	}

	/// The longest a close driver may wait for new input before re-checking
	/// close progress: the time until the nearest FINISH grace deadline (the
	/// Host's own or any session's), clamped at zero, or `None` when no finite
	/// deadline is pending and only host activity can advance terminal
	/// progress. Native refusal reaches the close driver; treating it as "no
	/// deadline" would turn a diagnosable failure into an unbounded park.
	pub(crate) fn close_wait(&self) -> Result<Option<Duration>> {
		let mut wait_ms: i64 = -1;
		let rc = unsafe { ffi::glowcap_host_close_wait_ms(self.raw(), monotonic_ms(), &mut wait_ms) };
		check_host(rc)?;
		decode_close_wait(wait_ms)
	}

	pub(crate) fn start_owned_task(self: &Rc<Self>) -> Result<OwnedTaskRegistration> {
		let count = self
			.owned_tasks
			.get()
			.checked_add(1)
			.ok_or_else(|| Error::with_detail(sys::ERR_INTERNAL, "Host-owned task count exhausted".to_string()))?;
		self.owned_tasks.set(count);
		Ok(OwnedTaskRegistration {
			host: Rc::downgrade(self),
		})
	}

	fn owned_task_finished(self: &Rc<Self>) {
		let Some(remaining) = self.owned_tasks.get().checked_sub(1) else {
			self.record_background_failure(Error::with_detail(
				sys::ERR_INTERNAL,
				"Host-owned task registration underflow".to_string(),
			));
			return;
		};
		self.owned_tasks.set(remaining);
		if remaining == 0 {
			self.release_notify.notify_waiters();
		}
	}

	/// Spawn one detached DIAL executor under this Host's terminal lifetime.
	/// Tokio cancellation is the right primitive here: every binding task runs
	/// on one current-thread LocalSet, so close cannot race a task currently on
	/// another thread, and `abort` prevents its next poll before native teardown.
	pub(crate) fn spawn_dial_task<F, Fut>(self: &Rc<Self>, ticket: u64, route_index: usize, run: F) -> Result<bool>
	where
		F: FnOnce(Rc<HostShared>) -> Fut + 'static,
		Fut: Future<Output = ()> + 'static,
	{
		if self.raw.get().is_null() {
			return Ok(false);
		}
		let host = Rc::clone(self);
		let registration = DialTaskRegistration {
			host: Rc::downgrade(self),
			attempt: (ticket, route_index),
			_owned: self.start_owned_task()?,
		};
		let Some(task) = try_spawn_local_handle(async move {
			let _registration = registration;
			let observer = Rc::clone(&host);
			let mut inner = AbortTaskOnDrop(Some(tokio::task::spawn_local(run(host))));
			let outcome = match inner.0.as_mut() {
				Some(handle) => handle.await,
				None => return,
			};
			inner.0.take();
			if let Err(join) = outcome {
				let primary = if join.is_panic() {
					Error::with_detail(
						sys::ERR_INTERNAL,
						format!(
							"dial task panicked: {}",
							crate::panic_message(join.into_panic().as_ref())
						),
					)
				} else {
					Error::with_detail(sys::ERR_INTERNAL, format!("dial task failed: {join}"))
				};
				let cancellation =
					check_host(unsafe { ffi::glowcap_host_dial_cancelled(observer.raw(), ticket, route_index) });
				observer.record_background_failure(crate::retain_cleanup_failure(primary, cancellation));
			}
		}) else {
			return Ok(false);
		};
		self.dial_tasks.borrow_mut().insert((ticket, route_index), task);
		Ok(true)
	}

	pub(crate) async fn cancel_dial_task(&self, ticket: u64, route_index: usize) -> Result<()> {
		let task = self.dial_tasks.borrow_mut().remove(&(ticket, route_index));
		let task_failure = if let Some(task) = task {
			task.abort();
			match task.await {
				Ok(()) => None,
				Err(join) if join.is_cancelled() => None,
				Err(join) if join.is_panic() => Some(Error::with_detail(
					sys::ERR_INTERNAL,
					format!(
						"dial task panicked: {}",
						crate::panic_message(join.into_panic().as_ref())
					),
				)),
				Err(join) => Some(Error::with_detail(
					sys::ERR_INTERNAL,
					format!("dial task join failed: {join}"),
				)),
			}
		} else {
			None
		};
		let cancellation = check_host(unsafe { ffi::glowcap_host_dial_cancelled(self.raw(), ticket, route_index) });
		match task_failure {
			Some(primary) => Err(crate::retain_cleanup_failure(primary, cancellation)),
			None => cancellation,
		}
	}
	/// Terminally release this Host. A callback cannot free the native Host
	/// whose actor cell is on its stack, so it parks one Host-owned transaction;
	/// the outer feed or local-run drain performs the same ordered teardown.
	pub(crate) fn close_host(self: &Rc<HostShared>, pending: PendingWork) -> Result<()> {
		pending.to_ffi()?;
		match self.close_barrier.get() {
			CloseBarrierState::Complete(code) => return close_result(code),
			CloseBarrierState::Failed => return Err(self.retained_close_failure()),
			CloseBarrierState::Idle | CloseBarrierState::Running => {}
		}
		// A loop-adopted Host tears down through its loop, which releases the
		// wrapped native Host itself; `loop_teardown` (called back from
		// `LoopShared::close`) retires this wrapper's shells and vows.
		#[cfg(not(target_arch = "wasm32"))]
		if let Some(lp) = self.driver_loop() {
			return lp.request_close(pending);
		}
		self.request_native_release(pending)
	}

	pub(super) async fn wait_closed(&self) -> Result<()> {
		loop {
			let notified = self.release_notify.notified();
			match self.close_barrier.get() {
				CloseBarrierState::Complete(code) => return close_result(code),
				CloseBarrierState::Failed => return Err(self.retained_close_failure()),
				CloseBarrierState::Idle | CloseBarrierState::Running => notified.await,
			}
		}
	}

	/// Release Session shells that unregistered while their callbacks were
	/// still on the stack. They are absent from `sessions`, but the native Host
	/// still owns them and must not be freed first.
	fn drain_parked_sessions(self: &Rc<HostShared>) -> Result<()> {
		crate::finalizer::drain_host_sessions(self)
	}

	fn request_native_release(self: &Rc<HostShared>, pending: PendingWork) -> Result<()> {
		self.drain_parked_sessions()?;
		let options = pending.to_ffi()?;
		let rc = unsafe { ffi::glowcap_host_close(self.raw(), &options, monotonic_ms()) };
		if rc != sys::OK {
			return check_host(rc);
		}
		self.native_close_committed();
		// A close request or escalation is close-relevant activity: a driver
		// parked on a now-superseded wait must re-check progress.
		self.note_close_activity();
		if !self.close_task_started.get() {
			let host = Rc::clone(self);
			if try_spawn_local_handle(async move { host.drive_native_close().await }).is_none() {
				return Err(Error::with_detail(
					sys::ERR_INTERNAL,
					"host close requires a running LocalSet".into(),
				));
			}
			self.close_task_started.set(true);
		}
		Ok(())
	}

	async fn drive_native_close(self: Rc<HostShared>) {
		let close_code = loop {
			if self.close_barrier.get() != CloseBarrierState::Running {
				return;
			}
			// Register the activity waiter before the progress check, so a
			// verb completing between the check and the await still wakes
			// this loop instead of being lost.
			let notified = self.close_activity();
			tokio::pin!(notified);
			notified.as_mut().enable();
			let mut lifecycle = 0;
			let rc = unsafe { ffi::glowcap_host_close_progress(self.raw(), monotonic_ms(), &mut lifecycle) };
			if rc != sys::OK && rc != sys::ERR_TIMEOUT {
				self.fail_close(host_refusal(rc, "advancing host close"));
				return;
			}
			let closed = match crate::lifecycle_is_closed(lifecycle) {
				Ok(closed) => closed,
				Err(error) => {
					self.fail_close(error);
					return;
				}
			};
			if closed {
				break rc;
			}
			// Drain what progress queued before parking. A productive drain
			// signals the waiter registered above, forcing one more progress
			// check rather than parking over undrained work.
			if let Err(error) = self.kick_actions().await {
				self.fail_close(error);
				return;
			}
			// Wake on host activity or on the nearest FINISH grace deadline;
			// with no finite deadline pending, only activity can advance
			// terminal progress, so the driver parks on activity alone.
			match self.close_wait() {
				Ok(Some(wait)) => {
					tokio::select! {
						() = notified.as_mut() => {}
						() = crate::execution::sleep(wait) => {}
					}
				}
				Ok(None) => notified.await,
				Err(error) => {
					self.fail_close(error);
					return;
				}
			}
		};
		loop {
			let notified = self.release_notify.notified();
			if self.owned_tasks.get() == 0 {
				break;
			}
			notified.await;
		}
		self.finish_native_release(close_code);
	}

	fn finish_native_release(self: &Rc<HostShared>, close_code: i32) {
		if self.close_barrier.get() != CloseBarrierState::Running {
			return;
		}
		// A task may fail after the close driver's final action drain but before
		// its owned-task count reaches zero. Claim that exact cause here, at the
		// last surviving barrier, while still releasing native state below.
		let background_failure = match (
			self.take_background_failure(),
			self.retirement_failure.borrow_mut().take(),
		) {
			(Some(primary), Some(retirement)) => Some(primary.with_secondary(retirement)),
			(primary, retirement) => primary.or(retirement),
		};
		let raw = self.raw.get();
		if raw.is_null() {
			if let Some(error) = background_failure {
				*self.close_failure.borrow_mut() = Some(error);
				self.close_barrier.set(CloseBarrierState::Failed);
			} else {
				self.close_barrier.set(CloseBarrierState::Complete(close_code));
			}
			self.release_notify.notify_waiters();
			return;
		}
		debug_assert_eq!(self.owned_tasks.get(), 0);
		if let Err(error) = self.drain_parked_sessions() {
			self.fail_close(background_failure.map_or(error.clone(), |primary| primary.with_secondary(error)));
			return;
		}
		debug_assert!(self.sessions.borrow().is_empty());
		debug_assert!(self.vows.only_settled());
		let rc = unsafe { ffi::glowcap_host_release(raw) };
		if rc != sys::OK {
			let release = host_refusal(rc, "releasing host");
			if crate::lifecycle::release_consumed(rc) {
				self.retire_native_host(raw);
			}
			self.fail_close(background_failure.map_or(release.clone(), |primary| primary.with_secondary(release)));
			return;
		}
		self.retire_native_host(raw);
		if let Some(error) = background_failure {
			*self.close_failure.borrow_mut() = Some(error);
			self.close_barrier.set(CloseBarrierState::Failed);
		} else {
			self.close_barrier.set(CloseBarrierState::Complete(close_code));
		}
		self.release_notify.notify_waiters();
	}

	fn retire_native_host(&self, raw: *mut ffi::GlowcapHost) {
		crate::trace::detach_host(raw);
		self.raw.set(core::ptr::null_mut());
		crate::gc::retire(self);
		self.vows.clear();
		// Native release ran every ctx-free callback. These maps contain only
		// non-owning pointers and cannot retain stale lookup results afterward.
	}
}

fn decode_close_wait(wait_ms: i64) -> Result<Option<Duration>> {
	match wait_ms {
		-1 => Ok(None),
		0.. => Ok(Some(Duration::from_millis(u64::try_from(wait_ms).map_err(|_| {
			Error::with_detail(
				sys::ERR_INTERNAL,
				"native close wait exceeded the duration range".into(),
			)
		})?))),
		_ => Err(Error::with_detail(
			sys::ERR_INTERNAL,
			format!("native close wait returned invalid negative duration {wait_ms}"),
		)),
	}
}

impl Drop for HostShared {
	fn drop(&mut self) {
		// A loop-adopted Host's native handle dies with `glowcap_driver_release`
		// (at the loop's own drop), never through `glowcap_host_release`. The
		// wrapper dropping without an explicit close still closes the loop, so
		// the park task and the native loop cannot outlive every handle.
		#[cfg(not(target_arch = "wasm32"))]
		if let Some(lp) = self.driver_loop.get_mut().take() {
			let raw = self.raw.replace(core::ptr::null_mut());
			if !raw.is_null() {
				crate::trace::detach_host(raw);
			}
			lp.close();
			return;
		}
		let raw = self.raw.get();
		if raw.is_null() {
			return;
		}
		// The release is refused inside a callback; park it for the next drain
		// rather than dropping it on the floor.
		if inside_turn() {
			self.raw.set(core::ptr::null_mut());
			crate::finalizer::park_host(raw, self.context.take(), false);
		} else {
			crate::trace::detach_host(raw);
			let rc = unsafe { ffi::glowcap_host_release(raw) };
			if crate::lifecycle::release_consumed(rc) {
				self.raw.set(core::ptr::null_mut());
			}
			if rc != sys::OK {
				if let Err(error) = check_host(rc) {
					crate::record_runtime_failure(crate::FailureLayer::Binding, "host-drop-release", error);
				}
				if !crate::lifecycle::release_consumed(rc) {
					crate::finalizer::park_host(raw, self.context.take(), true);
				}
			}
		}
	}
}

#[cfg(test)]
mod close_wait_tests {
	use super::*;

	#[test]
	fn decodes_close_wait_contract() {
		assert_eq!(decode_close_wait(-1).unwrap(), None);
		assert_eq!(decode_close_wait(0).unwrap(), Some(Duration::ZERO));
		assert_eq!(decode_close_wait(42).unwrap(), Some(Duration::from_millis(42)));
	}

	#[test]
	fn refuses_out_of_contract_negative_close_wait() {
		let error = decode_close_wait(-2).unwrap_err();
		assert_eq!(error.code(), sys::ERR_INTERNAL);
		assert_eq!(
			error.message(),
			Some("native close wait returned invalid negative duration -2")
		);
	}
}
