//! A volatile engine whose storage works wait on a gate the test opens, so a
//! scenario can act while a work is in flight.
use super::*;
use std::sync::{Arc, Condvar, Mutex};

/// Holds every storage work until the test opens the gate.
#[derive(Default)]
pub(super) struct Gate {
	state: Mutex<(bool, usize)>,
	changed: Condvar,
}
impl Gate {
	pub(super) fn open(&self) {
		self.state.lock().unwrap().0 = true;
		self.changed.notify_all();
	}
	pub(super) fn entered(&self) -> usize {
		self.state.lock().unwrap().1
	}
	/// Open the gate when the guard drops, so a failed assertion cannot
	/// leave a held worker that the unwinding Host joins forever.
	pub(super) fn opened_on_drop(self: &Arc<Self>) -> OpenOnDrop {
		OpenOnDrop(Arc::clone(self))
	}
	fn hold(&self) {
		let mut state = self.state.lock().unwrap();
		state.1 += 1;
		while !state.0 {
			state = self.changed.wait(state).unwrap();
		}
	}
}
pub(super) struct OpenOnDrop(Arc<Gate>);
impl Drop for OpenOnDrop {
	fn drop(&mut self) {
		self.0.open();
	}
}
/// Which works wait, and where.
#[derive(Clone, Copy)]
pub(super) enum Hold {
	/// Every work, before it touches the engine.
	BeforeRun,
	/// Only writes, after the commit has landed in the engine but before the
	/// Host installs its completion.
	AfterCommit,
}
struct Held {
	inner: Arc<dyn Executor>,
	gate: Arc<Gate>,
	hold: Hold,
}
impl Executor for Held {
	fn work_run(&self, work: *mut ffi::GlowcapLoamWork) -> i32 {
		let mut kind = 0;
		// SAFETY: the worker holds this exclusive work handle until it retires,
		// and the kind is fixed when the work is created.
		let rc = unsafe { ffi::glowcap_loam_work_kind(work, &mut kind) };
		assert_eq!(rc, crate::sys::OK);
		if let Hold::BeforeRun = self.hold {
			self.gate.hold();
		}
		let code = self.inner.work_run(work);
		if let (Hold::AfterCommit, 1) = (self.hold, kind) {
			self.gate.hold();
		}
		code
	}
	fn restore(
		&self,
		attachment: *mut ffi::GlowcapLoamAttachment,
		object: *const ffi::GlowcapLoamObject,
		out_ref: *mut crate::sys::GlowcapReference,
	) -> i32 {
		self.inner.restore(attachment, object, out_ref)
	}
	fn commit(&self) -> i32 {
		self.inner.commit()
	}
	fn collect(&self, work_limit: usize) -> i32 {
		self.inner.collect(work_limit)
	}
	fn recover(&self) -> i32 {
		self.inner.recover()
	}
	fn release(&self) -> i32 {
		self.inner.release()
	}
	fn last_error(&self, buf: &mut [u8]) -> usize {
		self.inner.last_error(buf)
	}
}
pub(super) struct HeldVolatile(pub(super) Arc<Gate>, pub(super) Hold);
impl Engine for HeldVolatile {}
impl super::super::executor::sealed::Open for HeldVolatile {
	fn open(
		self,
		schemas: &[ffi::GlowcapLoamSchema],
		limits: &ffi::GlowcapLoamLimits,
	) -> Result<(Arc<dyn Executor>, *mut ffi::GlowcapLoamStore)> {
		let volatile = Volatile {
			identity: [4; 16],
			capacity_bytes: 8 * 1024 * 1024,
		};
		let (inner, store) = super::super::executor::sealed::Open::open(volatile, schemas, limits)?;
		Ok((
			Arc::new(Held {
				inner,
				gate: self.0,
				hold: self.1,
			}),
			store,
		))
	}
}
