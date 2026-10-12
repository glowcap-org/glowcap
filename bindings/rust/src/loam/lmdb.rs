//! Native Store startup and explicit commit-outcome recovery.
use super::{Limits, Resource, Schema, Store, StoreInner, check, ffi, invalid};
use crate::Result;
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
};
impl Store {
	/// Open LMDB with an explicit physical map budget (at least 1 MiB). This
	/// limit is independent of resident and staged record bytes in `Limits`.
	#[cfg(not(target_arch = "wasm32"))]
	pub fn open(
		path: &std::path::Path,
		identity: [u8; 16],
		create: bool,
		map_bytes: usize,
		schemas: &[Schema],
		limits: Limits,
	) -> Result<Self> {
		Self::open_mode(path, identity, u32::from(create), map_bytes, schemas, limits)
	}
	/// Atomically initialize an absent Store or reopen its exact persisted
	/// identity. The embedding must persist that identity before calling.
	pub fn open_bootstrap(
		path: &std::path::Path,
		identity: [u8; 16],
		map_bytes: usize,
		schemas: &[Schema],
		limits: Limits,
	) -> Result<Self> {
		Self::open_mode(path, identity, 2, map_bytes, schemas, limits)
	}
	fn open_mode(
		path: &std::path::Path,
		identity: [u8; 16],
		mode: u32,
		map_bytes: usize,
		schemas: &[Schema],
		limits: Limits,
	) -> Result<Self> {
		// SAFETY: `glowcap_loam_archive_fingerprint` takes no arguments and returns a constant of the linked archive;
		// there is no handle or pointer to keep alive.
		if unsafe { ffi::glowcap_loam_archive_fingerprint() } != ffi::LOAM_ARCHIVE_FINGERPRINT
			// SAFETY: as the first fingerprint call above, for the LMDB archive.
			|| unsafe { ffi::glowcap_loam_lmdb_archive_fingerprint() } != ffi::LOAM_LMDB_ARCHIVE_FINGERPRINT
		{
			return Err(invalid("Loam archive contract mismatch"));
		}
		let path = path.to_str().ok_or_else(|| invalid("store path is not UTF-8"))?;
		let schemas: Vec<_> = schemas.iter().map(|s| s.raw()).collect();
		let mut storage = core::ptr::null_mut();
		let mut store = core::ptr::null_mut();
		check(
			// SAFETY: `path` is a `&str` borrowed from the caller's `Path`, `identity` is a `[u8; 16]` array, and
			// `schemas` is the local `Vec` of schema views built above, all live for the whole call; the callee copies
			// the limits and schemas (header). `&limits.raw()` is a temporary that lives to the end of this statement,
			// and `storage` and `store` are local out-parameters the callee writes, null on refusal.
			unsafe {
				ffi::glowcap_loam_lmdb_open(
					path.as_ptr(),
					path.len(),
					identity.as_ptr(),
					mode,
					map_bytes,
					schemas.as_ptr(),
					schemas.len(),
					&limits.raw(),
					&mut storage,
					&mut store,
				)
			},
			true,
		)?;
		Ok(Self {
			inner: Rc::new(StoreInner {
				storage: Cell::new(storage),
				store,
				pending_creation: RefCell::new(None),
			}),
		})
	}
	/// Resolve an indeterminate creation after the synchronous commit returned.
	/// The output stays retained until the core proves commit or absence.
	#[cfg(not(target_arch = "wasm32"))]
	pub fn recover_creation(&self) -> Result<Resource> {
		let resource = self
			.inner
			.pending_creation
			.borrow()
			.as_ref()
			.copied()
			.ok_or_else(|| invalid("there is no retained creation result"))?;
		// SAFETY: `self.inner.storage` is this `StoreInner`'s `GlowcapLoamLmdb` handle from `glowcap_loam_lmdb_open`,
		// released only by `StoreInner::close`, which nulls it afterward; the callee refuses a null handle with a
		// status rather than reading it, and the call takes no other pointer.
		let rc = unsafe { ffi::glowcap_loam_lmdb_recover(self.inner.storage.get()) };
		if rc == crate::sys::OK || rc == ffi::GLOWCAP_LOAM_ERR_UNCHANGED {
			self.inner.pending_creation.borrow_mut().take();
		}
		check(rc, true)?;
		Ok(resource)
	}
	/// Refusal preserves the storage owner. The C Store's borrow counts decide
	/// whether attachments and effects still prevent release.
	#[cfg(not(target_arch = "wasm32"))]
	pub fn close(&mut self) -> Result<()> {
		self.inner.close()
	}
}
