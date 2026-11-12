//! Raw handle custody at the sidecars' C boundary. Both FFI crates compile
//! this module. The runtime crate remains independent of unsafe pointer access.

use std::panic::{AssertUnwindSafe, catch_unwind};

/// Borrow one handle, refusing null and containing panics inside the C call.
/// Buffers and their capacities remain the entry point's responsibility.
///
/// # Safety
/// `handle` is null or points to a live value from its matching constructor.
/// No call may free that value until `body` returns.
pub(crate) unsafe fn borrowed<H, R: Copy>(handle: *const H, refused: R, body: impl FnOnce(&H) -> R) -> R {
	// SAFETY: the caller keeps the value live, and as_ref handles null.
	catch_unwind(AssertUnwindSafe(|| match unsafe { handle.as_ref() } {
		Some(handle) => body(handle),
		None => refused,
	}))
	.unwrap_or(refused)
}

/// Consume an owned handle exactly once, answering zero for null or success
/// and -1 for a teardown error or panic. No reference may survive reclamation.
///
/// # Safety
/// `handle` is null or came from Box::into_raw and has not been reclaimed.
/// All borrows and concurrent operations must have ended before this call.
pub(crate) unsafe fn reclaimed<H, E>(handle: *mut H, body: impl FnOnce(Box<H>) -> Result<(), E>) -> i32 {
	if handle.is_null() {
		return 0;
	}
	glowcap_sidecar_runtime::teardown_status(|| {
		// SAFETY: the caller transfers this non-null allocation with no live borrows.
		body(unsafe { Box::from_raw(handle) })
	})
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::sync::atomic::{AtomicUsize, Ordering};

	struct Counted<'a>(&'a AtomicUsize);

	impl Drop for Counted<'_> {
		fn drop(&mut self) {
			self.0.fetch_add(1, Ordering::SeqCst);
		}
	}

	#[test]
	fn borrowing_refuses_null_and_contains_panics() {
		let value = 7;
		// SAFETY: only null and a reference to a live stack value are passed.
		unsafe {
			assert_eq!(
				borrowed::<i32, _>(std::ptr::null(), -1, |_| panic!("null reached body")),
				-1
			);
			assert_eq!(borrowed(&value, -1, |value| *value), 7);
			assert_eq!(borrowed(&value, -1, |_| panic!("borrow panic")), -1);
		}
	}

	#[test]
	fn reclamation_drops_once_on_success_error_and_panic() {
		let drops = AtomicUsize::new(0);
		for outcome in 0..3 {
			let raw = Box::into_raw(Box::new(Counted(&drops)));
			// SAFETY: each iteration transfers one fresh Box with no outstanding borrow.
			let result = unsafe {
				reclaimed(raw, |_owned| match outcome {
					0 => Ok(()),
					1 => Err(()),
					_ => panic!("teardown panic"),
				})
			};
			assert_eq!(result, if outcome == 0 { 0 } else { -1 });
			assert_eq!(drops.load(Ordering::SeqCst), outcome + 1);
		}
		// SAFETY: reclamation accepts null without calling the body.
		let refused = unsafe { reclaimed::<i32, ()>(std::ptr::null_mut(), |_| panic!("null reached body")) };
		assert_eq!(refused, 0);
	}
}
