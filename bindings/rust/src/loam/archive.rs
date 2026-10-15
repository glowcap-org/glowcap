//! An engine's C archive as one table of symbols, and the executor that
//! drives a store through it. Each engine names its table and calls its own
//! open symbol, so the execution bodies exist once for every engine.
use super::{Executor, ffi, invalid};
use crate::Result;
use crate::sys::GlowcapReference;
use std::{path::Path, sync::Arc};

/// How a store is opened.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OpenMode {
	/// Open an existing store.
	Open,
	/// Create a store, refusing one that already exists.
	Create,
	/// Atomically initialize an absent Store or reopen its exact persisted
	/// identity. The embedding must persist that identity before calling.
	Bootstrap,
}

/// The symbols one engine archive exports, each taking its opaque handle `T`.
pub(super) struct Archive<T: 'static> {
	pub fingerprint: unsafe extern "C" fn() -> u64,
	/// The fingerprint this crate was generated against.
	pub expected: u64,
	pub work_run: unsafe extern "C" fn(*mut T, *mut ffi::GlowcapLoamWork) -> i32,
	pub restore: unsafe extern "C" fn(
		*mut T,
		*mut ffi::GlowcapLoamAttachment,
		*const ffi::GlowcapLoamObject,
		*mut GlowcapReference,
	) -> i32,
	pub commit: unsafe extern "C" fn(*mut T) -> i32,
	pub collect: unsafe extern "C" fn(*mut T, usize) -> i32,
	pub recover: unsafe extern "C" fn(*mut T) -> i32,
	pub release: unsafe extern "C" fn(*mut T) -> i32,
	pub last_error: unsafe extern "C" fn(*mut u8, usize) -> usize,
}

impl OpenMode {
	/// The `create` argument every archive's open takes.
	pub(super) fn code(self) -> u32 {
		match self {
			OpenMode::Open => 0,
			OpenMode::Create => 1,
			OpenMode::Bootstrap => 2,
		}
	}
}

/// A disk archive's open symbol: a path, then the arguments every open takes,
/// with the engine's one size argument after the mode.
pub(super) type DiskOpen<T> = unsafe extern "C" fn(
	*const u8,
	usize,
	*const u8,
	u32,
	usize,
	*const ffi::GlowcapLoamSchema,
	usize,
	*const ffi::GlowcapLoamLimits,
	*mut *mut T,
	*mut *mut ffi::GlowcapLoamStore,
) -> i32;

/// Refuse an archive built from another contract than this crate's.
pub(super) fn check_fingerprint<T>(archive: &Archive<T>) -> Result<()> {
	// SAFETY: the fingerprint symbol takes no arguments and returns a constant of the linked archive; there is no
	// handle or pointer to keep alive.
	if unsafe { (archive.fingerprint)() } != archive.expected {
		return Err(invalid("Loam archive contract mismatch"));
	}
	Ok(())
}

/// Open a disk store through `archive`. `size` is the engine's one size argument.
#[allow(clippy::too_many_arguments)]
pub(super) fn open_disk<T: 'static>(
	archive: &'static Archive<T>,
	open: DiskOpen<T>,
	path: &Path,
	identity: &[u8; 16],
	mode: OpenMode,
	size: usize,
	schemas: &[ffi::GlowcapLoamSchema],
	limits: &ffi::GlowcapLoamLimits,
) -> Result<(Arc<dyn Executor>, *mut ffi::GlowcapLoamStore)> {
	check_fingerprint(archive)?;
	let path = path.to_str().ok_or_else(|| invalid("store path is not UTF-8"))?;
	let mut raw = core::ptr::null_mut();
	let mut store = core::ptr::null_mut();
	// SAFETY: `path`, `identity`, `schemas`, and `limits` are borrowed and live for the whole call, and the callee
	// copies the limits and schemas (header). `raw` and `store` are local out-parameters the callee writes, null on
	// refusal.
	let rc = unsafe {
		open(
			path.as_ptr(),
			path.len(),
			identity.as_ptr(),
			mode.code(),
			size,
			schemas.as_ptr(),
			schemas.len(),
			limits,
			&mut raw,
			&mut store,
		)
	};
	adopt(archive, rc, raw, store)
}

/// Turn an open symbol's result into the executor that owns its handle. A
/// refusal reads the archive's last error and leaves nothing to release.
pub(super) fn adopt<T: 'static>(
	archive: &'static Archive<T>,
	rc: i32,
	raw: *mut T,
	store: *mut ffi::GlowcapLoamStore,
) -> Result<(Arc<dyn Executor>, *mut ffi::GlowcapLoamStore)> {
	let executor = ArchiveExecutor { archive, raw };
	executor.check(rc)?;
	Ok((Arc::new(executor), store))
}

/// The storage owner behind a Store. Dropping it does not release the
/// handle: `StoreInner::close` or the finalizer calls `release`.
struct ArchiveExecutor<T: 'static> {
	archive: &'static Archive<T>,
	raw: *mut T,
}
// SAFETY: the C worker contract lets `work_run` run off-thread on immutable submitted buffers and backend state.
// Every other method is called on the owner thread, and the retirement guard joins the job before release.
unsafe impl<T> Send for ArchiveExecutor<T> {}
// SAFETY: the `Arc` is reachable only from `StoreInner`, `StorageJob`, and the finalizer, and only `StorageJob`
// leaves the owner thread, calling nothing but `work_run`.
unsafe impl<T> Sync for ArchiveExecutor<T> {}

impl<T> Executor for ArchiveExecutor<T> {
	fn work_run(&self, work: *mut ffi::GlowcapLoamWork) -> i32 {
		// SAFETY: `self.raw` is the owner from the archive's open, released only after the retirement guard joins
		// this call, and `work` is the work handle from `glowcap_loam_next_work` that the caller exclusively holds
		// until the job retires.
		unsafe { (self.archive.work_run)(self.raw, work) }
	}
	fn restore(
		&self,
		attachment: *mut ffi::GlowcapLoamAttachment,
		object: *const ffi::GlowcapLoamObject,
		out_ref: *mut GlowcapReference,
	) -> i32 {
		// SAFETY: `self.raw` is the owner from the archive's open, live until released; the caller keeps
		// `attachment` live, passes a borrowed `object` the callee only reads, and passes `out_ref` as an
		// out-parameter the callee fills.
		unsafe { (self.archive.restore)(self.raw, attachment, object, out_ref) }
	}
	fn commit(&self) -> i32 {
		// SAFETY: `self.raw` is the owner from the archive's open, released only by `release`; the call takes no
		// other pointer and runs on the Host thread outside any turn.
		unsafe { (self.archive.commit)(self.raw) }
	}
	fn collect(&self, work_limit: usize) -> i32 {
		// SAFETY: `self.raw` is the owner from the archive's open, released only by `release`; the call takes no
		// other pointer and runs on the Host thread outside any turn.
		unsafe { (self.archive.collect)(self.raw, work_limit) }
	}
	fn recover(&self) -> i32 {
		// SAFETY: `self.raw` is the owner from the archive's open, still live until a release consumes it; the call
		// takes no other pointer.
		unsafe { (self.archive.recover)(self.raw) }
	}
	fn release(&self) -> i32 {
		// SAFETY: `self.raw` is the owner from the archive's open; the callers release it once on success, never
		// concurrently with a `work_run` the retirement guard has not joined, and a refusal such as Busy leaves it
		// alive for a retry. The call takes no other pointer.
		unsafe { (self.archive.release)(self.raw) }
	}
	fn last_error(&self, buf: &mut [u8]) -> usize {
		// SAFETY: `buf` is a live mutable slice; the reader needs no handle, reads the calling thread's last-error
		// slot, and copies at most `buf.len()` bytes into it, returning the count.
		unsafe { (self.archive.last_error)(buf.as_mut_ptr(), buf.len()) }
	}
}
