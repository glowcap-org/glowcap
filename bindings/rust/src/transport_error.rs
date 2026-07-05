//! The per-transport error-slot pair (ADR-0059): each transport archive keeps
//! its own thread-local last-error, so each transport module mints its
//! checker/reader pair from its archive's extern reader here instead of
//! pasting the bodies.

// Generates a transport module's error-slot pair: `$check(code)` maps a non-OK
// return code to an `Error` carrying the slot's message, and `$reader()`
// snapshots the calling thread's last error message from `$extern_reader`, or
// `None` if none is set. The archive keeps its own thread-local slot, so a
// transport call's diagnostic is read through this pair and never from the
// ocapn family's `last_error`.
macro_rules! transport_error_slot {
	($check:ident, $reader:ident, $extern_reader:path) => {
		fn $check(code: i32) -> crate::Result<()> {
			if code == crate::sys::OK {
				Ok(())
			} else {
				Err(crate::Error::with_transport_detail(code, $reader()))
			}
		}

		fn $reader() -> Option<String> {
			let len = unsafe { $extern_reader(core::ptr::null_mut(), 0) };
			if len == 0 {
				return None;
			}
			let mut buf = vec![0u8; len + 1];
			let written = unsafe { $extern_reader(buf.as_mut_ptr(), buf.len()) };
			buf.truncate(written.min(buf.len()));
			Some(String::from_utf8_lossy(&buf).into_owned())
		}
	};
}

pub(crate) use transport_error_slot;
