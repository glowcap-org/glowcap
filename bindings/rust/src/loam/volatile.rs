//! The in-memory storage engine for a Rust Store.
use super::archive::{self, Archive, OpenMode};
use super::{Engine, Executor, executor::sealed, ffi};
use crate::Result;
use std::sync::Arc;

/// The in-memory engine. Each open creates a new store that lives until the
/// Store closes, holding at most `capacity_bytes` of keys and values,
/// independent of the resident and staged record bytes in `Limits`.
#[derive(Clone, Debug)]
pub struct Volatile {
	pub identity: [u8; 16],
	pub capacity_bytes: usize,
}

impl Engine for Volatile {}

impl sealed::Open for Volatile {
	fn open(
		self,
		schemas: &[ffi::GlowcapLoamSchema],
		limits: &ffi::GlowcapLoamLimits,
	) -> Result<(Arc<dyn Executor>, *mut ffi::GlowcapLoamStore)> {
		archive::check_fingerprint(&ARCHIVE)?;
		let mut raw = core::ptr::null_mut();
		let mut store = core::ptr::null_mut();
		// SAFETY: `self.identity` is a `[u8; 16]` array, and `schemas` and `limits` are the caller's borrowed slice and
		// reference, all live for the whole call; the callee copies the limits and schemas (header). `raw` and `store`
		// are local out-parameters the callee writes, null on refusal.
		let rc = unsafe {
			ffi::glowcap_loam_volatile_open(
				self.identity.as_ptr(),
				OpenMode::Create.code(),
				self.capacity_bytes,
				schemas.as_ptr(),
				schemas.len(),
				limits,
				&mut raw,
				&mut store,
			)
		};
		archive::adopt(&ARCHIVE, rc, raw, store)
	}
}

static ARCHIVE: Archive<ffi::GlowcapLoamVolatile> = Archive {
	fingerprint: ffi::glowcap_loam_volatile_archive_fingerprint,
	expected: ffi::LOAM_VOLATILE_ARCHIVE_FINGERPRINT,
	work_run: ffi::glowcap_loam_volatile_work_run,
	restore: ffi::glowcap_loam_volatile_restore,
	commit: ffi::glowcap_loam_volatile_commit,
	collect: ffi::glowcap_loam_volatile_collect,
	recover: ffi::glowcap_loam_volatile_recover,
	release: ffi::glowcap_loam_volatile_release,
	last_error: ffi::glowcap_loam_volatile_last_error,
};
