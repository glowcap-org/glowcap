//! The per-archive error-slot pair (ADR-0022): every glowcap archive keeps its
//! own thread-local last-error (`glowcap_last_error` for the ocapn core,
//! `glowcap_host_last_error` for the driver, `glowcap_<t>_last_error` per
//! transport), so each consumer module mints its checker/reader pair from its
//! archive's extern reader here instead of pasting the two-pass read.

// Generates one archive's error-slot pair: `$check(code)` maps a non-OK return
// code to an `Error` carrying the slot's message, and `$reader()` snapshots the
// calling thread's last error message from `$extern_reader`, or `None` if none
// is set. Doc attributes and visibility pass through per function, so a public
// reader (the core's `last_error`) and a private transport pair mint from the
// same definition. The read is two-pass: a null probe for the length, then a
// `len + 1` buffer: the C side reserves one byte for a NUL terminator and
// copies at most `cap - 1` message bytes, so the second call receives all
// `len` of them.
macro_rules! error_slot {
	(
		$(#[$check_meta:meta])*
		$check_vis:vis fn $check:ident;
		$(#[$reader_meta:meta])*
		$reader_vis:vis fn $reader:ident;
		$extern_reader:path
	) => {
		$(#[$check_meta])*
		$check_vis fn $check(code: i32) -> crate::Result<()> {
			if code == crate::sys::OK {
				Ok(())
			} else {
				Err(crate::Error::with_transport_detail(code, $reader()))
			}
		}

		$(#[$reader_meta])*
		$reader_vis fn $reader() -> Option<String> {
			// SAFETY: `$extern_reader` is an archive's `*_last_error` reader, which reads that archive's thread-local
			// slot and needs no handle; the null buffer with capacity zero is the length probe, so the callee writes
			// nothing and returns the message length.
			let len = unsafe { $extern_reader(core::ptr::null_mut(), 0) };
			if len == 0 {
				return None;
			}
			let mut buf = vec![0u8; len + 1];
			// SAFETY: as the probe above; `buf` is a local `Vec<u8>` of `len + 1` bytes, live for the call, and the
			// callee writes at most `buf.len() - 1` message bytes plus a NUL terminator and returns the count written.
			let written = unsafe { $extern_reader(buf.as_mut_ptr(), buf.len()) };
			buf.truncate(written.min(buf.len()));
			Some(String::from_utf8_lossy(&buf).into_owned())
		}
	};
}

pub(crate) use error_slot;
