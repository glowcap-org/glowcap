//! Browser jobs retain the attachment until IndexedDB physically retires.
use super::super::{AttachmentInner, check};
use super::{callback, retained};
use crate::{Result, sys::loam as ffi};
use std::rc::Rc;

pub(crate) async fn execute(owner: Rc<AttachmentInner>, raw: *mut ffi::GlowcapLoamWork) -> Result<i32> {
	retained(async move {
		struct Custody {
			owner: Rc<AttachmentInner>,
			raw: *mut ffi::GlowcapLoamWork,
			released: bool,
		}
		impl Drop for Custody {
			fn drop(&mut self) {
				if !self.released {
					crate::finalizer::park_loam_work(Rc::clone(&self.owner), self.raw);
					self.owner.host.schedule_kick_or_record();
				}
			}
		}
		let mut custody = Custody {
			owner: Rc::clone(&owner),
			raw,
			released: false,
		};
		let mut kind = 0;
		check(unsafe { ffi::glowcap_loam_work_kind(raw, &mut kind) }, false)?;
		let terminal = owner
			.store
			.backend
			.transaction(kind == 1, move |plan| {
				Ok(unsafe { ffi::glowcap_loam_work_plan(raw, Some(callback), plan.context()) })
			})
			.await;
		check(unsafe { ffi::glowcap_loam_work_finish(raw, terminal.outcome) }, false)?;
		let mut completed = 0;
		let rc = unsafe { ffi::glowcap_loam_work_complete(raw, &mut completed) };
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
				return Err(check(rc, false)
					.expect_err("non-success completion")
					.with_secondary(error));
			}
		}
		Ok(rc)
	})
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
