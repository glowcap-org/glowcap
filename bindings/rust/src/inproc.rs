//! The blocking in-process transport (the `inproc` feature).
//!
//! This module wraps `libglowcap_net_transport_inproc`: the `glowcap_inproc_*`
//! archive that the `inproc` Cargo feature links (ADR-0059). It is the
//! socket-free sibling of [`tcp`](crate::tcp): two peers in one process are
//! wired by in-process pipes, with no kernel transport. The C listener adds a
//! wake descriptor for reactor integration. No application bytes flow through it.
//! A [`Listener`] binds to a string designator (any opaque token, not a
//! `host:port`) and a dialer names that designator. Otherwise the frame shuttle
//! is identical: a [`Connection`] reads and writes one whole CapTP frame at a
//! time, and the frame methods block.
//!
//! Errors from a `glowcap_inproc_*` call route through the transport archive's
//! own thread-local last-error
//! (`glowcap_inproc_last_error`),
//! never the ocapn family's [`last_error`](crate::last_error).

use core::marker::PhantomData;
use std::sync::{Arc, Mutex};

use crate::error_slot::error_slot;
use crate::sys::inproc as ffi;
use crate::{Codec, Error, HintWireForm, Locator, Result};

fn lock_failure(slot: &Mutex<Option<Error>>) -> std::sync::MutexGuard<'_, Option<Error>> {
	slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Build a hint-free locator for an in-process switchboard name.
pub fn locator(designator: &str) -> Locator {
	Locator {
		transport: crate::TRANSPORT_INPROC.to_string(),
		designator: designator.to_string(),
		hints: std::collections::BTreeMap::new(),
		hint_wire_form: HintWireForm::BooleanFalse,
	}
}

error_slot!(
	// Like the core `check`, but for `glowcap_inproc_*` calls: snapshot the
	// in-process transport's own thread-local last-error.
	fn check_inproc;
	fn inproc_last_error;
	ffi::glowcap_inproc_last_error
);

fn require_archive() -> Result<()> {
	crate::require_archive_fingerprint(
		"inproc",
		// SAFETY: `glowcap_inproc_archive_fingerprint` takes no arguments and returns an integer by value, so it
		// touches no Rust memory.
		unsafe { ffi::glowcap_inproc_archive_fingerprint() },
		crate::abi_constants::INPROC_ARCHIVE_FINGERPRINT,
	)
}

/// Owns the in-process switchboard and its one I/O backend, on the
/// library-owned allocator. Connections and listeners borrow it (via `&self`),
/// so the borrow checker rejects a [`Connection`] or [`Listener`] that outlives
/// the netlayer that produced it.
pub struct Netlayer {
	raw: *mut ffi::GlowcapInprocNetlayer,
	listener_close_failure: Arc<Mutex<Option<Error>>>,
}

impl Netlayer {
	pub fn new() -> Result<Netlayer> {
		require_archive()?;
		let mut raw: *mut ffi::GlowcapInprocNetlayer = core::ptr::null_mut();
		// SAFETY: `raw` is a local out-parameter the callee fills with the new netlayer handle, which `Netlayer::drop`
		// releases.
		check_inproc(unsafe { ffi::glowcap_inproc_netlayer_new(&mut raw) })?;
		Ok(Netlayer {
			raw,
			listener_close_failure: Arc::new(Mutex::new(None)),
		})
	}

	/// Bind an in-process listener on `designator` (any opaque token). The
	/// returned listener borrows this netlayer and cannot outlive it.
	pub fn listen(&self, designator: &str) -> Result<Listener<'_>> {
		let mut raw: *mut ffi::GlowcapInprocListener = core::ptr::null_mut();
		// SAFETY: `self.raw` is this `Netlayer`'s handle from `glowcap_inproc_netlayer_new`, released only by its
		// `Drop`; `designator` is a borrowed `str` whose pointer and length stay live for the call; `raw` is an
		// out-parameter the callee fills.
		check_inproc(unsafe { ffi::glowcap_inproc_listen(self.raw, designator.as_ptr(), designator.len(), &mut raw) })?;
		Ok(Listener {
			raw,
			close_failure: Arc::clone(&self.listener_close_failure),
			_nl: PhantomData,
		})
	}

	/// Dial the listener bound at `designator`, framing on `codec` with an
	/// inbound cap of `max_frame_bytes`. The returned connection borrows this
	/// netlayer and cannot outlive it.
	pub fn connect(&self, designator: &str, codec: Codec, max_frame_bytes: usize) -> Result<Connection<'_>> {
		let mut raw: *mut ffi::GlowcapInprocConn = core::ptr::null_mut();
		// SAFETY: `self.raw` is this `Netlayer`'s handle from `glowcap_inproc_netlayer_new`, released only by its
		// `Drop`; `designator` is a borrowed `str` whose pointer and length stay live for the call; `raw` is an
		// out-parameter the callee fills, and the null error buffer with length zero asks for no error text.
		check_inproc(unsafe {
			ffi::glowcap_inproc_connect(
				self.raw,
				designator.as_ptr(),
				designator.len(),
				codec.to_c(),
				max_frame_bytes,
				&mut raw,
				core::ptr::null_mut(),
				0,
				core::ptr::null_mut(),
			)
		})?;
		Ok(Connection { raw, _nl: PhantomData })
	}

	/// Return and clear the first listener failure retained by implicit drop.
	pub fn take_listener_close_failure(&self) -> Option<Error> {
		lock_failure(&self.listener_close_failure).take()
	}

	/// Release the netlayer and report any listener close failure retained by
	/// implicit destruction. The borrow checker guarantees every listener has
	/// already retired before this consuming barrier can run.
	pub fn close(self) -> Result<()> {
		if let Some(error) = self.take_listener_close_failure() {
			return Err(error);
		}
		Ok(())
	}
}

impl Drop for Netlayer {
	fn drop(&mut self) {
		// SAFETY: `self.raw` is this `Netlayer`'s handle from `glowcap_inproc_netlayer_new`, released only by its
		// `Drop`, so the release runs once after every borrowing `Listener` and `Connection` is gone.
		unsafe { ffi::glowcap_inproc_netlayer_release(self.raw) };
	}
}

/// A bound in-process listener. Released on drop. Borrows the [`Netlayer`] it
/// came from, so the netlayer outlives every accepted connection.
pub struct Listener<'a> {
	raw: *mut ffi::GlowcapInprocListener,
	close_failure: Arc<Mutex<Option<Error>>>,
	_nl: PhantomData<&'a ()>,
}

impl Listener<'_> {
	/// Return the borrowed wake descriptor for reactor integration. The
	/// listener owns it. Callers must not close it or retain it after drop.
	pub fn readiness_fd(&self) -> Result<i32> {
		let mut fd: i32 = -1;
		// SAFETY: `self.raw` is this `Listener`'s handle from `Netlayer::listen`, released only by its `Drop`; its `'a`
		// borrow keeps the netlayer alive; `fd` is an out-parameter the callee writes; the listener keeps owning the
		// descriptor.
		check_inproc(unsafe { ffi::glowcap_inproc_listener_readiness_fd(self.raw, &mut fd) })?;
		Ok(fd)
	}

	/// Block until a dialer connects. The returned connection borrows this
	/// listener (and thus the netlayer) and cannot outlive it.
	pub fn accept(&self, codec: Codec, max_frame_bytes: usize) -> Result<Connection<'_>> {
		let mut raw: *mut ffi::GlowcapInprocConn = core::ptr::null_mut();
		// SAFETY: `self.raw` is this `Listener`'s handle from `Netlayer::listen`, released only by its `Drop`; its `'a`
		// borrow keeps the netlayer alive; `raw` is an out-parameter the callee fills, and the null error buffer with
		// length zero asks for no error text.
		check_inproc(unsafe {
			ffi::glowcap_inproc_accept(
				self.raw,
				codec.to_c(),
				max_frame_bytes,
				&mut raw,
				core::ptr::null_mut(),
				0,
				core::ptr::null_mut(),
			)
		})?;
		Ok(Connection { raw, _nl: PhantomData })
	}

	fn release(&mut self) -> Result<()> {
		if self.raw.is_null() {
			return Ok(());
		}
		let raw = core::mem::replace(&mut self.raw, core::ptr::null_mut());
		// SAFETY: `raw` is this `Listener`'s handle from `Netlayer::listen`, moved out of `self.raw` just above and
		// non-null, so it is released exactly once and `Drop` sees null afterward; the netlayer outlives it through the
		// `'a` borrow, and the null error buffer with length zero asks for no error text.
		check_inproc(unsafe {
			ffi::glowcap_inproc_listener_release(raw, core::ptr::null_mut(), 0, core::ptr::null_mut())
		})
	}

	/// Close explicitly and return the FFI teardown failure, if any.
	pub fn close(mut self) -> Result<()> {
		self.release()
	}
}

// SAFETY: a `Listener` owns a self-contained payload, its own bound
// switchboard slot plus a copy of the netlayer's allocator, and shares no
// per-handle mutable state with the netlayer or sibling handles, so moving it to
// the accepting thread and calling `accept` there touches only its own state.
// The state it shares with the netlayer is thread-safe: the allocator
// (`std.heap.smp_allocator`) and the in-process switchboard/`std.Io.Threaded`
// backend, which tolerates the concurrent connect-on-origin / accept-off-thread
// rendezvous the committed scoped-thread test exercises. Borrowing the netlayer
// keeps it non-`'static`, so callers move it into a scoped thread.
unsafe impl Send for Listener<'_> {}

impl Drop for Listener<'_> {
	fn drop(&mut self) {
		if let Err(error) = self.release() {
			let mut retained = lock_failure(&self.close_failure);
			if retained.is_none() {
				*retained = Some(error);
			}
		}
	}
}

/// A blocking in-process connection, the `glowcap_inproc_*` frame shuttle.
/// Closed on drop. The frame methods block. Borrows the [`Netlayer`] (or
/// [`Listener`]) it came from, so that backend outlives it.
pub struct Connection<'a> {
	raw: *mut ffi::GlowcapInprocConn,
	_nl: PhantomData<&'a ()>,
}

impl Connection<'_> {
	/// Block for one whole frame. [`ErrorKind::Closed`](crate::ErrorKind::Closed)
	/// reports a clean EOF.
	pub fn read_frame(&mut self) -> Result<Vec<u8>> {
		// SAFETY: `GlowcapManagedFrame` is a plain C struct of integers, null pointers, and an `Option` function
		// pointer; all-zero is a valid value, and the callee fills it before it is read.
		let mut frame: crate::sys::GlowcapManagedFrame = unsafe { core::mem::zeroed() };
		// SAFETY: `self.raw` is this `Connection`'s handle from `connect` or `accept`, released only by its `Drop`; its
		// `'a` borrow keeps the backend alive; `frame` is an out-parameter the callee fills, and the null error buffer
		// with length zero asks for no error text.
		check_inproc(unsafe {
			ffi::glowcap_inproc_conn_read_frame(self.raw, &mut frame, core::ptr::null_mut(), 0, core::ptr::null_mut())
		})?;
		// SAFETY: on success `read_frame` filled `frame.bytes` and `frame.len` with a view the frame owns until
		// `glowcap_managed_frame_release` runs on the next line, and `owned_from_view` copies it first; it handles a
		// null pointer or zero length.
		let out = unsafe { crate::owned_from_view(frame.bytes, frame.len) };
		// SAFETY: `frame` was filled by the successful `read_frame` call above and is released exactly once, after the
		// copy.
		unsafe { crate::sys::glowcap_managed_frame_release(&mut frame) };
		Ok(out)
	}

	/// Write one frame's bytes into the partner's pipe.
	pub fn write_frame(&mut self, bytes: &[u8]) -> Result<()> {
		let f = crate::sys::GlowcapFrame {
			bytes: bytes.as_ptr(),
			len: bytes.len(),
			shape: crate::sys::FRAME_SHAPE_BYTE,
		};
		// SAFETY: `self.raw` is this `Connection`'s handle from `connect` or `accept`, released only by its `Drop`; its
		// `'a` borrow keeps the backend alive; `f` is a local `GlowcapFrame` whose `bytes` and `len` come from the
		// borrowed `bytes` slice, live for the call, and the callee reads it only during the call.
		check_inproc(unsafe {
			ffi::glowcap_inproc_conn_write_frame(self.raw, &f, core::ptr::null_mut(), 0, core::ptr::null_mut())
		})
	}
}

// SAFETY: a `Connection` owns a self-contained payload, its own in-process pipe
// half plus a copy of the netlayer's allocator, and shares no per-handle
// mutable state with the netlayer or sibling handles, so moving it to another
// thread and doing frame I/O on it touches only its own state. The allocator and
// the switchboard/`std.Io.Threaded` backend it shares are thread-safe under the
// concurrent blocking calls a borrowed handle makes off-thread (see `Listener`
// above).
unsafe impl Send for Connection<'_> {}

impl Drop for Connection<'_> {
	fn drop(&mut self) {
		// SAFETY: `self.raw` is this `Connection`'s handle from `connect` or `accept`, released only by its `Drop`; its
		// `'a` borrow keeps the backend alive, so the release runs once after every borrow of it ends.
		unsafe { ffi::glowcap_inproc_conn_release(self.raw) };
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::Codec;

	// Two peers wired by an in-process pipe, no socket, shuttle one whole
	// frame across the switchboard, proving the `inproc` archive composes with
	// the core exactly as the tcp one does.
	#[test]
	fn shuttles_a_frame_over_an_in_process_pipe() {
		let netlayer = Netlayer::new().unwrap();
		let listener = netlayer.listen("demo").unwrap();

		let received = std::thread::scope(|scope| {
			let server = scope.spawn(move || {
				let mut conn = listener.accept(Codec::Syrup, 4096).unwrap();
				conn.read_frame().unwrap()
			});

			let mut client = netlayer.connect("demo", Codec::Syrup, 4096).unwrap();
			client.write_frame(b"<8'op:abort3\"bye>").unwrap();

			server.join().unwrap()
		});
		assert_eq!(received, b"<8'op:abort3\"bye>");
	}

	// A dial to a designator with no bound listener fails with the transport's
	// own diagnostic, read from `glowcap_inproc_last_error` rather than the
	// ocapn family's slot.
	#[test]
	fn dialing_an_unbound_designator_reports_the_inproc_error() {
		let netlayer = Netlayer::new().unwrap();
		// `Connection` is not `Debug` (an opaque connection handle), so match
		// rather than `unwrap_err`. The diagnostic comes from the inproc
		// transport's own last-error slot via `check_inproc`.
		let dialed = netlayer.connect("nobody-home", Codec::Syrup, 4096);
		match dialed {
			Ok(_) => panic!("dialing an unbound designator should fail"),
			Err(err) => assert_ne!(err.code(), crate::sys::OK),
		}
	}
}
