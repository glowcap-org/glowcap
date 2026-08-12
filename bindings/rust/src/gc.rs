//! Distributed GC (ADR-0063), opt-in and off by default. Owns the
//! [`ImportGuard`] death rite, fetch [`track_import`], and the
//! `pancake_host_ref_release` drain. Session holds only the opt-in flag; the
//! Host owns the pending queue because a Ref may outlive its arrival session.
//! Binding spine Pass 3b.

use std::cell::Cell;
use std::rc::{Rc, Weak};

use crate::host::HostShared;
use crate::session_shared::SessionShared;
use crate::sys::host as ffi;
use crate::Ref;

/// Drops to one parked `pancake_host_ref_release` delta of 1 for a Host id.
/// The drop only parks the id and schedules the Host action drain —
/// it may run inside a behavior trampoline (a behavior dropping a `Ref`), where
/// the host-driving verbs are refused, so the release itself always runs on the
/// pumping task, never here.
#[derive(Debug)]
pub(crate) struct ImportGuard {
	pub(crate) token: u64,
	pub(crate) host: Weak<HostShared>,
	armed: Cell<bool>,
}

impl Drop for ImportGuard {
	fn drop(&mut self) {
		if self.armed.get() {
			if let Some(host) = self.host.upgrade() {
				host.gc_pending.borrow_mut().push(self.token);
				host.schedule_kick();
			}
		}
	}
}

/// Drain the parked GC releases: one release delta per reclaimed token. The
/// op:gc-exports flush rides the kick `ImportGuard::drop` scheduled when it
/// parked the id, so the drain itself never kicks. Best-effort — a refused
/// release strands a partner export reclaimed at teardown, never a fault.
/// Called at the head of Host progress and whenever a finalizer schedules it.
pub(crate) fn drain(host: &HostShared) {
	if host.raw().is_null() {
		return;
	}
	let pending: Vec<u64> = std::mem::take(&mut *host.gc_pending.borrow_mut());
	if pending.is_empty() {
		return;
	}
	for token in pending {
		let raw = crate::sys::PancakeReference { id: token };
		let _ = unsafe { ffi::pancake_host_ref_release(host.raw(), &raw, 1) };
	}
}

/// Build an [`ImportGuard`] when GC is on.
pub(crate) fn guard_for(session: &Rc<SessionShared>, id: u64) -> Option<Rc<ImportGuard>> {
	if !session.gc.get() {
		return None;
	}
	Some(Rc::new(ImportGuard {
		token: id,
		host: Rc::downgrade(&session.host),
		armed: Cell::new(true),
	}))
}

pub(crate) fn disarm(reference: &Ref) {
	if let Some(guard) = reference.guard() {
		guard.armed.set(false);
	}
}

/// Wrap a fetched capability into a [`Ref`]. The Host resolves its opaque id
/// to the capability and any corresponding wire retain when release fires.
/// The guard captures only the bare id, never the `Ref`.
pub(crate) fn track_import(shared: &Rc<SessionShared>, reference: Ref) -> Ref {
	if let Some(guard) = guard_for(shared, reference.id()) {
		return Ref::tracked_id(reference.id(), guard);
	}
	reference
}

/// Release one capability retain deterministically, because the application says it is
/// done with the capability rather than because a handle dropped.
///
/// Lives here beside the finalizer path because both end in the same Host verb.
pub(crate) fn release_ref(
	host_raw: *mut crate::sys::host::PancakeHost,
	id: u64,
) -> crate::Result<()> {
	let raw = crate::sys::PancakeReference { id };
	let rc = unsafe { crate::sys::host::pancake_host_ref_release(host_raw, &raw, 1) };
	crate::host::check_host(rc)
}
