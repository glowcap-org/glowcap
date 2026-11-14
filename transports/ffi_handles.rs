//! Raw handle custody and caller-buffer projection at the sidecars' C boundary.
//! Both FFI crates compile this module. The runtime crate remains independent
//! of unsafe pointer access.

use std::mem::MaybeUninit;
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Borrow one handle, refusing null and containing panics inside the C call.
/// Buffers go through `caller_slice` and `caller_out`.
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

/// Whether `len` values of `T` occupy at most `isize::MAX` bytes, the bound
/// `slice::from_raw_parts` requires.
fn byte_size_fits<T>(len: usize) -> bool {
	len.checked_mul(std::mem::size_of::<T>())
		.is_some_and(|bytes| bytes <= isize::MAX as usize)
}

/// Turn a caller's `ptr + len` into a shared slice. A zero `len` is an empty
/// slice and never reads `ptr`. A null `ptr` with nonzero `len`, or a byte size
/// above `isize::MAX`, answers `None` before any slice forms.
///
/// # Safety
/// When `len` is nonzero, `ptr` is aligned for `T` and points to `len`
/// initialized `T` that stay live and unmodified for `'a`.
pub(crate) unsafe fn caller_slice<'a, T>(ptr: *const T, len: usize) -> Option<&'a [T]> {
	if len == 0 {
		return Some(&[]);
	}
	if ptr.is_null() || !byte_size_fits::<T>(len) {
		return None;
	}
	// SAFETY: `ptr` is non-null and the byte size fits `isize`, and the caller vouches for alignment and `len` valid
	// elements.
	Some(unsafe { std::slice::from_raw_parts(ptr, len) })
}

/// Turn a caller's out-buffer `ptr + len` into exclusive uninitialized slots,
/// refusing exactly what `caller_slice` refuses.
///
/// # Safety
/// When `len` is nonzero, `ptr` is aligned for `T` and addresses `len` writable
/// slots that stay live for `'a` and are accessed by nothing else.
pub(crate) unsafe fn caller_out<'a, T>(ptr: *mut T, len: usize) -> Option<&'a mut [MaybeUninit<T>]> {
	if len == 0 {
		return Some(&mut []);
	}
	if ptr.is_null() || !byte_size_fits::<T>(len) {
		return None;
	}
	// SAFETY: `ptr` is non-null and the byte size fits `isize`, and the caller vouches for alignment, exclusivity, and
	// `len` slots. `MaybeUninit<T>` has the layout of `T` and claims no initialization.
	Some(unsafe { std::slice::from_raw_parts_mut(ptr.cast::<MaybeUninit<T>>(), len) })
}

/// Drain up to `cap` readiness records into fresh uninitialized slots and return
/// the initialized ones.
#[cfg(test)]
pub(crate) fn drain_records<E: From<(usize, u32)> + Copy>(
	readiness: &glowcap_sidecar_runtime::Readiness<E>,
	cap: usize,
) -> Vec<E> {
	let mut slots = vec![MaybeUninit::uninit(); cap];
	let count = readiness.drain(&mut slots);
	slots[..count]
		.iter()
		// SAFETY: `drain` initialized exactly its first `count` slots.
		.map(|slot| unsafe { slot.assume_init() })
		.collect()
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
	fn caller_slices_answer_each_outcome() {
		let mut bytes = [1u8, 2, 3];
		let huge = usize::MAX / 2 + 1;
		// SAFETY: every refused case stops before a slice forms, and the accepted cases cover `bytes` exactly.
		unsafe {
			assert_eq!(caller_slice::<u8>(std::ptr::null(), 0), Some(&[][..]));
			assert_eq!(
				caller_out::<u8>(std::ptr::null_mut(), 0).map(|slots| slots.len()),
				Some(0)
			);
			assert_eq!(caller_slice::<u8>(std::ptr::null(), 1), None);
			assert!(caller_out::<u8>(std::ptr::null_mut(), 1).is_none());
			assert_eq!(caller_slice(bytes.as_ptr(), huge), None);
			assert_eq!(caller_slice(bytes.as_ptr(), usize::MAX), None);
			assert_eq!(caller_slice(std::ptr::NonNull::<u16>::dangling().as_ptr(), huge), None);
			assert!(caller_out(bytes.as_mut_ptr(), huge).is_none());
			assert_eq!(caller_slice(bytes.as_ptr(), 3), Some(&[1u8, 2, 3][..]));
			let slots = caller_out(bytes.as_mut_ptr(), 2).unwrap();
			assert_eq!(slots.len(), 2);
			slots[0].write(9);
			assert_eq!(bytes, [9, 2, 3]);
		}
	}

	#[test]
	fn byte_size_bound_is_exact() {
		let max = isize::MAX as usize;
		assert!(byte_size_fits::<u8>(max));
		assert!(!byte_size_fits::<u8>(max + 1));
		assert!(byte_size_fits::<u16>(max / 2));
		assert!(!byte_size_fits::<u16>(max / 2 + 1));
		assert!(!byte_size_fits::<u8>(usize::MAX));
		assert!(byte_size_fits::<()>(usize::MAX));
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
