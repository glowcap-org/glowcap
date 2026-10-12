//! Exactly-once foreign context transfer, independent of refusal status.
use super::{ActorCell, Cell, Error, Result, drop_actor_cell, sys};

struct Receipt<'a> {
	cell: *mut ActorCell,
	retired: &'a Cell<bool>,
}

impl Drop for Receipt<'_> {
	fn drop(&mut self) {
		if !self.retired.get() {
			// The callback is synchronous and Host handles are thread-confined.
			// Clear the stack address before the native-owned cell escapes.
			// SAFETY: `self.cell` is the `ActorCell` that `register_actor_cell` was handed; this branch runs only while
			// `retired` is false, meaning `ctx_free` has not run and the cell has not been reclaimed (the reclaim path
			// sets `retired` first), so the allocation is still live, and the Host's single thread makes no concurrent
			// access.
			unsafe {
				(*self.cell).registration.set(core::ptr::null());
			}
		}
	}
}

/// Run one C ABI registration with a stack receipt observed by ctx_free.
/// INVALID_ARGUMENT can occur both before transfer (reentry) and after it
/// (a durable-name collision). The status cannot answer who owns the cell.
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
	// SAFETY: the caller declares `cell` fresh and unregistered, so nothing else
	// holds it while this frame installs the receipt.
	unsafe { (*cell).registration.set(&retired) };
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
			// SAFETY: a negative code with the receipt unset means the Host
			// never took the cell, so this frame is still its only owner.
			drop_actor_cell(unsafe { Box::from_raw(cell) })
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
