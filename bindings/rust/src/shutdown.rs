use core::marker::PhantomData;

/// A borrowed, concurrent shutdown entry. Dropping this handle does not release
/// the owner or shut it down.
pub struct ShutdownHandle<'owner, T: Target> {
	raw: *mut T,
	_owner: PhantomData<&'owner T>,
}

/// The shutdown operation supported by an opaque transport handle.
///
/// # Safety
/// Implementations must allow shutdown to race all operations except release,
/// including other shutdown calls, and must not release the handle.
pub unsafe trait Target {
	type Output;

	/// # Safety
	/// `raw` must be a live handle until this call returns, or null if the
	/// transport permits shutdown of a closed owner.
	unsafe fn shutdown(raw: *mut Self) -> Self::Output;
}

impl<'owner, T: Target> ShutdownHandle<'owner, T> {
	/// # Safety
	/// The owning wrapper must remain unreleased for `'owner`. A null handle
	/// is permitted only when the transport accepts it after owner closure.
	pub(crate) unsafe fn borrowed(raw: *mut T) -> Self {
		Self {
			raw,
			_owner: PhantomData,
		}
	}

	/// Seal admission and wake blocked operations. Idempotent. The owner still
	/// releases its storage, and the transport determines whether shutdown can fail.
	pub fn shutdown(&self) -> T::Output {
		// SAFETY: construction ties the raw handle to its owner's live borrow.
		unsafe { T::shutdown(self.raw) }
	}
}

// SAFETY: Target permits concurrent shutdown, and the borrow prevents release.
unsafe impl<T: Target> Send for ShutdownHandle<'_, T> {}
// SAFETY: Target permits simultaneous shutdown calls on the same live handle.
unsafe impl<T: Target> Sync for ShutdownHandle<'_, T> {}
