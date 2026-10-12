//! Browser jobs retain the attachment until IndexedDB physically retires.
use super::super::{AttachmentInner, check};
use super::{callback, retained, retained_on_host};
use crate::{Result, sys::loam as ffi};
use std::rc::Rc;

/// Constructed before relay admission, including when that task never runs.
/// Physical retirement parks only raw work. Host completion owns callbacks.
struct Custody {
	owner: Rc<AttachmentInner>,
	raw: *mut ffi::GlowcapLoamWork,
	started: bool,
	released: bool,
}
impl Drop for Custody {
	fn drop(&mut self) {
		self.owner.storage_jobs.set(self.owner.storage_jobs.get() - 1);
		self.owner.progress_changed.notify_waiters();
		if self.released {
			return;
		}
		if !self.started {
			// No transaction was submitted, so non-commit is established.
			if let Err(error) = check(unsafe { ffi::glowcap_loam_work_finish(self.raw, 1) }, false) {
				self.owner.host.record_background_failure(error);
			}
		}
		crate::finalizer::park_loam_work(Rc::clone(&self.owner), self.raw);
		self.owner.host.note_close_activity();
	}
}

pub(crate) async fn execute(owner: Rc<AttachmentInner>, raw: *mut ffi::GlowcapLoamWork) -> Result<()> {
	owner.storage_jobs.set(owner.storage_jobs.get() + 1);
	let custody = Custody {
		owner: Rc::clone(&owner),
		raw,
		started: false,
		released: false,
	};
	retained_on_host(
		Rc::clone(&owner.host),
		async move {
			let (mut custody, kind, terminal) = retained(async move {
				let mut custody = custody;
				let mut kind = 0;
				check(unsafe { ffi::glowcap_loam_work_kind(raw, &mut kind) }, false)?;
				custody.started = true;
				let terminal = owner
					.store
					.backend
					.transaction(kind == 1, move |plan| {
						Ok(unsafe { ffi::glowcap_loam_work_plan(raw, Some(callback), plan.context()) })
					})
					.await;
				check(unsafe { ffi::glowcap_loam_work_finish(raw, terminal.outcome) }, false)?;
				Ok((custody, kind, terminal))
			})
			.await?;
			let mut completed = 0;
			let rc = unsafe { ffi::glowcap_loam_work_complete(raw, &mut completed) };
			// Snapshot the completion diagnostic before release or another task
			// clears its thread-local slot. Only owned errors cross the relay.
			let completion = check(rc, false);
			if completed != 0 {
				check(unsafe { ffi::glowcap_loam_work_release(raw) }, false)?;
				custody.released = true;
			}
			if let Some(error) = terminal.failure {
				if rc == crate::sys::OK || (kind != 3 && rc == ffi::GLOWCAP_LOAM_ERR_RECOVERY_REQUIRED) {
					// Core completion has delivered refusal to the owning operation
					// or retained its recovery barrier. Preserve the physical cause
					// without turning one storage refusal into a Host-wide failure.
					crate::record_runtime_failure(crate::FailureLayer::Binding, "loam-browser.storage", error);
				} else {
					return Err(completion.expect_err("non-success completion").with_secondary(error));
				}
			}
			if rc == ffi::GLOWCAP_LOAM_ERR_RECOVERY_REQUIRED {
				Ok(())
			} else {
				completion
			}
		},
		None,
	)
	.await
}

pub(crate) fn finish_retired(owner: &Rc<AttachmentInner>, raw: *mut ffi::GlowcapLoamWork) -> bool {
	let mut completed = 0;
	let code = unsafe { ffi::glowcap_loam_work_complete(raw, &mut completed) };
	if completed == 0 {
		return false;
	}
	if code != crate::sys::OK
		&& code != ffi::GLOWCAP_LOAM_ERR_STALE_COMPLETION
		&& code != ffi::GLOWCAP_LOAM_ERR_RECOVERY_REQUIRED
		&& let Err(error) = check(code, false)
	{
		owner.host.record_background_failure(error);
	}
	if let Err(error) = check(unsafe { ffi::glowcap_loam_work_release(raw) }, false) {
		owner.host.record_background_failure(error);
		return false;
	}
	true
}
