//! How a Rust Store drives its storage engine: an engine opens, an executor runs the work.
use super::{Limits, Resource, Schema, Store, StoreInner, ffi, invalid};
use crate::Result;
use crate::sys::GlowcapReference;
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
};

/// An engine value describes how to open one store. This crate implements it
/// for each storage engine it links, since opening crosses that engine's C
/// archive, so the trait is sealed.
pub trait Engine: sealed::Open {}

pub(crate) mod sealed {
	use super::{Executor, Result, ffi};
	use std::sync::Arc;
	/// Opening yields the executor that drives the store and the core store
	/// handle it borrows.
	pub trait Open {
		fn open(
			self,
			schemas: &[ffi::GlowcapLoamSchema],
			limits: &ffi::GlowcapLoamLimits,
		) -> Result<(Arc<dyn Executor>, *mut ffi::GlowcapLoamStore)>;
	}
}

/// Each method runs one storage operation through the engine's C symbol
/// family. `Send + Sync` lets the blocking storage worker run `work_run` off
/// the owner thread. That effect accesses immutable submitted buffers and
/// backend state, never Host callbacks or turns. Each storage job holds an
/// `Arc`, the owner-thread retirement guard joins it before portable
/// completion, and only the job leaves the owner thread. No application
/// capability crosses here. The crate implements it beside each engine and
/// keeps it out of the public surface.
pub trait Executor: Send + Sync {
	fn work_run(&self, work: *mut ffi::GlowcapLoamWork) -> i32;
	fn restore(
		&self,
		attachment: *mut ffi::GlowcapLoamAttachment,
		object: *const ffi::GlowcapLoamObject,
		out_ref: *mut GlowcapReference,
	) -> i32;
	fn commit(&self) -> i32;
	fn collect(&self, work_limit: usize) -> i32;
	fn recover(&self) -> i32;
	fn release(&self) -> i32;
	fn last_error(&self, buf: &mut [u8]) -> usize;
	/// Turn a status code into an error carrying the engine's last detail.
	fn check(&self, code: i32) -> Result<()> {
		if code == crate::sys::OK {
			return Ok(());
		}
		let mut bytes = [0u8; 512];
		let len = self.last_error(&mut bytes);
		Err(crate::Error::with_detail(
			code,
			String::from_utf8_lossy(&bytes[..len]).into_owned(),
		))
	}
}

impl Store {
	/// Open a store through its storage engine. Opening performs blocking
	/// startup I/O, so call it before admitting application traffic.
	pub fn open(engine: impl Engine, schemas: &[Schema], limits: Limits) -> Result<Self> {
		// SAFETY: `glowcap_loam_archive_fingerprint` takes no arguments and returns a constant of the linked archive;
		// there is no handle or pointer to keep alive.
		if unsafe { ffi::glowcap_loam_archive_fingerprint() } != ffi::LOAM_ARCHIVE_FINGERPRINT {
			return Err(invalid("Loam archive contract mismatch"));
		}
		let schemas: Vec<_> = schemas.iter().map(|s| s.raw()).collect();
		let (executor, store) = engine.open(&schemas, &limits.raw())?;
		Ok(Self {
			inner: Rc::new(StoreInner {
				executor,
				released: Cell::new(false),
				store,
				pending_creation: RefCell::new(None),
			}),
		})
	}
	/// Resolve an indeterminate creation after the synchronous commit returned.
	/// The output stays retained until the core proves commit or absence.
	pub fn recover_creation(&self) -> Result<Resource> {
		let resource = self
			.inner
			.pending_creation
			.borrow()
			.as_ref()
			.copied()
			.ok_or_else(|| invalid("there is no retained creation result"))?;
		let executor = &self.inner.executor;
		let rc = executor.recover();
		if rc == crate::sys::OK || rc == ffi::GLOWCAP_LOAM_ERR_UNCHANGED {
			self.inner.pending_creation.borrow_mut().take();
		}
		executor.check(rc)?;
		Ok(resource)
	}
	/// Run one bounded collection step: `work_limit` units of clearing, tracing,
	/// or sweeping plus the steps that finish an open unit. Returns true while
	/// the cycle has more to do, and a call after it ends begins a new cycle. A
	/// step the engine refused or aborted committed nothing and returns the
	/// typed cause, like a commit.
	pub fn collect(&self, work_limit: usize) -> Result<bool> {
		let executor = &self.inner.executor;
		executor.check(executor.collect(work_limit))?;
		let mut collecting = 0u32;
		// SAFETY: `store` is the live portable Store the executor serves, released only by `close`, and
		// `collecting` is a valid output for the call.
		let rc = unsafe { ffi::glowcap_loam_store_collecting(self.inner.store, &mut collecting) };
		executor.check(rc)?;
		Ok(collecting != 0)
	}
	/// Refusal preserves the storage owner. The C Store's borrow counts decide
	/// whether attachments and effects still prevent release.
	pub fn close(&mut self) -> Result<()> {
		self.inner.close()
	}
}
