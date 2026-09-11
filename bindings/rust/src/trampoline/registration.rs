//! Exactly-once foreign context transfer, independent of refusal status.
use super::{drop_actor_cell, sys, ActorCell, Cell, Error, Result};

struct Receipt<'a> {
	cell: *mut ActorCell,
	retired: &'a Cell<bool>,
}

impl Drop for Receipt<'_> {
	fn drop(&mut self) {
		if !self.retired.get() {
			// The callback is synchronous and Host handles are thread-confined.
			// Clear the stack address before the native-owned cell escapes.
			unsafe {
				(*self.cell).registration.set(core::ptr::null());
			}
		}
	}
}

/// Run one C ABI registration with a stack receipt observed by ctx_free.
/// INVALID_ARGUMENT can occur both before transfer (reentry) and after it
/// (a durable-name collision); the status cannot answer who owns the cell.
///
/// # Safety
/// `cell` must be a fresh, unregistered ActorCell. `run` makes exactly one
/// synchronous registration call for it using the binding's ctx_free callback.
/// No other thread may access the Host or cell during this call.
pub(crate) unsafe fn register_actor_cell(
	cell: *mut ActorCell,
	run: impl FnOnce() -> i32,
	accepted: impl FnOnce(i32) -> bool,
) -> Result<i32> {
	let retired = Cell::new(false);
	(*cell).registration.set(&retired);
	let _receipt = Receipt {
		cell,
		retired: &retired,
	};
	let code = run();
	if !accepted(code) {
		// Snapshot the primary refusal before a caller-owned destructor can
		// itself report through the C ABI's diagnostic slot.
		let primary = crate::host::host_refusal(code, "actor registration");
		// An invalid nonnegative result is an ABI invariant failure, not proof
		// of refusal. A still-live cell may already belong to the native Host.
		let cleanup = if code >= 0 || retired.replace(true) {
			Ok(())
		} else {
			drop_actor_cell(Box::from_raw(cell))
		};
		return Err(crate::retain_cleanup_failure(primary, cleanup));
	}
	if retired.get() {
		return Err(Error::with_detail(
			sys::ERR_INTERNAL,
			"actor registration succeeded after freeing its context".into(),
		));
	}
	Ok(code)
}
