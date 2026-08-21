//! Loop and session close choreography over the native driver's authoritative
//! lifecycle and release barriers.

use super::*;

fn retain_release_failure(close_code: i32, release: Error) -> Error {
	match crate::host::close_result(close_code) {
		Ok(()) => release,
		Err(primary) => primary.with_secondary(release),
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn close_timeout_remains_primary_when_driver_release_also_fails() {
		let release = Error::with_detail(sys::ERR_IO, "provider release failed".to_string());
		let terminal = retain_release_failure(sys::ERR_TIMEOUT, release.clone());
		assert_eq!(terminal.code(), sys::ERR_TIMEOUT);
		assert_eq!(terminal.message(), Some("finish close exhausted its grace period"));
		assert_eq!(terminal.secondary_errors(), &[release]);
	}
}

impl LoopShared {
	pub(super) fn fail_close_or_record(&self, error: Error) {
		if let Some(host) = self.wrapper.borrow().as_ref().and_then(Weak::upgrade) {
			host.fail_close(error);
		} else {
			crate::record_runtime_failure(crate::FailureLayer::Driver, "driver-loop.close", error);
		}
	}

	pub(crate) fn request_session_close(
		self: &Rc<Self>,
		session: *mut ffi_host::PancakeHostSession,
		pending: PendingWork,
	) -> Result<()> {
		if self.released.get() {
			return Ok(());
		}
		self.guard_handle()?;
		self.driver.begin_session_close(session, pending)?;
		self.schedule_step();
		self.note_step_activity();
		Ok(())
	}

	pub(crate) fn request_close(self: &Rc<Self>, pending: PendingWork) -> Result<()> {
		if self.released.get() {
			return Ok(());
		}
		self.guard_handle()?;
		self.driver.begin_close(pending)?;
		self.note_step_activity();
		if let Some(host) = self.wrapper.borrow().as_ref().and_then(Weak::upgrade) {
			host.native_close_committed();
		}
		if !self.close_task_started.get() {
			let loop_ = Rc::clone(self);
			if try_spawn_local_handle(async move { loop_.drive_close().await }).is_none() {
				return Err(Error::with_detail(
					sys::ERR_INTERNAL,
					"loop close requires a running LocalSet".into(),
				));
			}
			self.close_task_started.set(true);
		}
		Ok(())
	}

	async fn drive_close(self: Rc<Self>) {
		let close_code = loop {
			let notified = self.step_activity();
			tokio::pin!(notified);
			notified.as_mut().enable();
			if let Err(error) = self.step_now() {
				self.fail_background(error);
				return;
			}
			match self.driver.lifecycle_state() {
				Ok((true, code)) => break code,
				Ok((false, _)) => match self.driver.step_wait() {
					Ok(Some(wait)) => {
						tokio::select! {
							() = notified.as_mut() => {}
							() = tokio::time::sleep(wait) => {}
						}
					}
					Ok(None) => notified.await,
					Err(error) => {
						self.fail_close_or_record(error);
						return;
					}
				},
				Err(error) => {
					self.fail_close_or_record(error);
					return;
				}
			}
		};

		if let Some(park) = self.park.borrow_mut().take() {
			park.abort();
		}
		debug_assert!(self.pending_dials.borrow().is_empty());
		debug_assert!(self.pending_listeners.borrow().is_empty());
		let host = self.wrapper.borrow().as_ref().and_then(Weak::upgrade);
		if let Some(host) = host {
			let release = self.driver.release();
			match release.result {
				Ok(()) if release.consumed => {
					self.released.set(true);
					host.finish_loop_teardown(close_code);
				}
				Err(error) if release.consumed => {
					self.released.set(true);
					host.finish_failed_loop_teardown(retain_release_failure(close_code, error));
				}
				Err(error) => {
					self.defer_failed_release(host, retain_release_failure(close_code, error));
				}
				Ok(()) => self.defer_failed_release(
					host,
					Error::with_detail(
						sys::ERR_INTERNAL,
						"driver release refused without a failure".to_string(),
					),
				),
			}
		} else {
			if let Err(error) = self.driver.release_or_defer() {
				self.fail_close_or_record(error);
				return;
			}
			self.released.set(true);
		}
		self.listeners.borrow_mut().clear();
		self.accepts.borrow_mut().clear();
		self.unclaimed_sessions.borrow_mut().clear();
		self.accept_wake.notify_waiters();
	}

	/// Implicit cleanup starts the ordinary cancel barrier when possible. If
	/// task admission itself fails, ownership transfers to the recurring raw
	/// release owner and the initiating failure remains primary.
	pub(crate) fn close(self: &Rc<Self>) {
		if let Err(primary) = self.request_close(PendingWork::Cancel) {
			let terminal = match self.driver.release_or_defer() {
				Ok(()) => primary,
				Err(cleanup) => primary.with_secondary(cleanup),
			};
			self.released.set(true);
			self.fail_close_or_record(terminal);
		}
	}
}
