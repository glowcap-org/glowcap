//! Distributed GC (ADR-0063), opt-in and off by default. Owns the
//! [`ImportGuard`] death rite, fetch [`track_import`], and the
//! `pancake_host_gc_release` drain. Session / SessionShared hold the enable flag
//! and pending queue; CapTP verbs call [`drain`] / [`track_import`]. Binding
//! spine Pass 3b.

use std::rc::{Rc, Weak};

use crate::session_shared::{Ref, SessionShared};
use crate::sys::driver as ffi;

/// Drops to one parked `pancake_host_gc_release` delta of 1 for `token`
/// (ADR-0063/ADR-0069). The drop only parks the token and pokes the serve task —
/// it may run inside a behavior trampoline (a behavior dropping a `Ref`), where
/// the host-driving verbs are refused, so the release itself always runs on the
/// pumping task, never here.
#[derive(Debug)]
pub(crate) struct ImportGuard {
	pub(crate) token: u64,
	pub(crate) conn: Weak<SessionShared>,
}

impl Drop for ImportGuard {
	fn drop(&mut self) {
		if let Some(conn) = self.conn.upgrade() {
			conn.gc_pending.borrow_mut().push(self.token);
			conn.gc_wakeup.notify_one();
		}
	}
}

/// Drain the parked GC releases: one release delta per reclaimed token, then
/// a kick so the op:gc-exports flushes. Best-effort — a refused release
/// strands a partner export reclaimed at teardown, never a fault. Called at
/// the head of the connection's own verbs and by the serve task when a
/// finalizer pokes it.
pub(crate) fn drain(conn: &SessionShared) {
	if conn.released.get() {
		return;
	}
	let pending: Vec<u64> = std::mem::take(&mut *conn.gc_pending.borrow_mut());
	if pending.is_empty() {
		return;
	}
	for token in pending {
		let _ = unsafe { ffi::pancake_host_gc_release(conn.host.raw(), token, 1) };
	}
	conn.host.schedule_kick();
}

/// Build an [`ImportGuard`] when GC is on and `id` is a redeemed token.
pub(crate) fn guard_for(conn: &Rc<SessionShared>, id: u64) -> Option<Rc<ImportGuard>> {
	if !conn.gc.get() || id < crate::sys::REDEEMED_TOKEN_BASE {
		return None;
	}
	Some(Rc::new(ImportGuard {
		token: id,
		conn: Rc::downgrade(conn),
	}))
}

/// Wrap a fetched capability into a [`Ref`]. The `Ref` holds a node-unique
/// token (ADR-0069) — only ids in the token range are tracked — and the host
/// resolves the token to its home connection and real wire import when the
/// release fires. The guard captures only the bare token, never the `Ref`.
pub(crate) fn track_import(shared: &Rc<SessionShared>, wire: crate::LiveRef) -> Ref {
	if let crate::LiveRef::Far { id, .. } = wire {
		if let Some(guard) = guard_for(shared, id) {
			return Ref::tracked(wire, guard);
		}
	}
	Ref::bare(wire)
}
