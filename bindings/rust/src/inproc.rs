//! The blocking in-process transport (the `inproc` feature).
//!
//! This module wraps `libpancake_net_transport_inproc` — the `pancake_inproc_*`
//! archive that the `inproc` Cargo feature links (ADR-0059). It is the
//! socket-free sibling of [`tcp`](crate::tcp): two peers in one process are
//! wired by in-process pipes, with no kernel transport. The C listener adds a
//! wake descriptor for reactor integration; no application bytes flow through it.
//! A [`Listener`] binds to a string designator (any opaque token, not a
//! `host:port`) and a dialer names that designator; otherwise the frame shuttle
//! is identical — a [`Connection`] reads and writes one whole CapTP frame at a
//! time, and the frame methods block.
//!
//! Errors from a `pancake_inproc_*` call route through the transport archive's
//! own thread-local last-error
//! (`pancake_inproc_last_error`),
//! never the ocapn family's [`last_error`](crate::last_error).

use core::marker::PhantomData;
use std::sync::{Arc, Mutex};

use crate::error_slot::error_slot;
use crate::sys::inproc as ffi;
use crate::{Codec, Context, Error, HintWireForm, Locator, Result};

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
	// Like the core `check`, but for `pancake_inproc_*` calls: snapshot the
	// in-process transport's own thread-local last-error.
	fn check_inproc;
	fn inproc_last_error;
	ffi::pancake_inproc_last_error
);

fn require_archive() -> Result<()> {
	crate::require_archive_fingerprint(
		"inproc",
		unsafe { ffi::pancake_inproc_archive_fingerprint() },
		crate::abi_constants::INPROC_ARCHIVE_FINGERPRINT,
	)
}

/// Owns the in-process switchboard and its one I/O backend. Connections and
/// listeners borrow it (via `&self`), so the borrow checker rejects an
/// [`Connection`] or [`Listener`] that outlives the netlayer that produced it. The
/// `'ctx` lifetime additionally ties a context-backed netlayer to its
/// [`Context`]; a netlayer on the library-owned allocator is `Netlayer<'static>`.
pub struct Netlayer<'ctx> {
	raw: *mut ffi::PancakeInprocNetlayer,
	listener_close_failure: Arc<Mutex<Option<Error>>>,
	_ctx: PhantomData<&'ctx Context>,
}

impl<'ctx> Netlayer<'ctx> {
	pub fn new() -> Result<Netlayer<'ctx>> {
		require_archive()?;
		let mut raw: *mut ffi::PancakeInprocNetlayer = core::ptr::null_mut();
		check_inproc(unsafe { ffi::pancake_inproc_netlayer_new(&mut raw) })?;
		Ok(Netlayer {
			raw,
			listener_close_failure: Arc::new(Mutex::new(None)),
			_ctx: PhantomData,
		})
	}

	/// Create a netlayer whose switchboard, backend, and per-connection buffers
	/// allocate through `context`. The context must outlive the netlayer, which
	/// `'ctx` enforces.
	pub fn new_in(context: &'ctx Context) -> Result<Netlayer<'ctx>> {
		require_archive()?;
		let mut raw: *mut ffi::PancakeInprocNetlayer = core::ptr::null_mut();
		check_inproc(unsafe { ffi::pancake_inproc_netlayer_new_in(context.raw(), &mut raw) })?;
		Ok(Netlayer {
			raw,
			listener_close_failure: Arc::new(Mutex::new(None)),
			_ctx: PhantomData,
		})
	}

	/// Bind an in-process listener on `designator` (any opaque token). The
	/// returned listener borrows this netlayer and cannot outlive it.
	pub fn listen(&self, designator: &str) -> Result<Listener<'_>> {
		let mut raw: *mut ffi::PancakeInprocListener = core::ptr::null_mut();
		check_inproc(unsafe { ffi::pancake_inproc_listen(self.raw, designator.as_ptr(), designator.len(), &mut raw) })?;
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
		let mut raw: *mut ffi::PancakeInprocConn = core::ptr::null_mut();
		check_inproc(unsafe {
			ffi::pancake_inproc_connect(
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

impl Drop for Netlayer<'_> {
	fn drop(&mut self) {
		unsafe { ffi::pancake_inproc_netlayer_release(self.raw) };
	}
}

/// A bound in-process listener. Released on drop. Borrows the [`Netlayer`] it
/// came from, so the netlayer outlives every accepted connection.
pub struct Listener<'a> {
	raw: *mut ffi::PancakeInprocListener,
	close_failure: Arc<Mutex<Option<Error>>>,
	_nl: PhantomData<&'a ()>,
}

impl Listener<'_> {
	/// Return the borrowed wake descriptor for reactor integration. The
	/// listener owns it; callers must not close it or retain it after drop.
	pub fn readiness_fd(&self) -> Result<i32> {
		let mut fd: i32 = -1;
		check_inproc(unsafe { ffi::pancake_inproc_listener_readiness_fd(self.raw, &mut fd) })?;
		Ok(fd)
	}

	/// Block until a dialer connects. The returned connection borrows this
	/// listener (and thus the netlayer) and cannot outlive it.
	pub fn accept(&self, codec: Codec, max_frame_bytes: usize) -> Result<Connection<'_>> {
		let mut raw: *mut ffi::PancakeInprocConn = core::ptr::null_mut();
		check_inproc(unsafe {
			ffi::pancake_inproc_accept(
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
		check_inproc(unsafe {
			ffi::pancake_inproc_listener_release(raw, core::ptr::null_mut(), 0, core::ptr::null_mut())
		})
	}

	/// Close explicitly and return the native teardown failure, if any.
	pub fn close(mut self) -> Result<()> {
		self.release()
	}
}

// SAFETY: a `Listener` owns a self-contained payload — its own bound
// switchboard slot plus a copy of the netlayer's allocator — and shares no
// per-handle mutable state with the netlayer or sibling handles, so moving it to
// the accepting thread and calling `accept` there touches only its own state.
// The state it shares with the netlayer is thread-safe: the allocator
// (`std.heap.smp_allocator` for `Netlayer::new`, or a bounded `Send + Sync`
// `ContextAllocator` for `new_in`) and the in-process switchboard/`std.Io.Threaded`
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

/// A blocking in-process connection, the `pancake_inproc_*` frame shuttle.
/// Closed on drop. The frame methods block. Borrows the [`Netlayer`] (or
/// [`Listener`]) it came from, so that backend outlives it.
pub struct Connection<'a> {
	raw: *mut ffi::PancakeInprocConn,
	_nl: PhantomData<&'a ()>,
}

impl Connection<'_> {
	/// Block for one whole frame. [`ErrorKind::Closed`](crate::ErrorKind::Closed)
	/// reports a clean EOF.
	pub fn read_frame(&mut self) -> Result<Vec<u8>> {
		let mut frame: crate::sys::PancakeManagedFrame = unsafe { core::mem::zeroed() };
		check_inproc(unsafe {
			ffi::pancake_inproc_conn_read_frame(self.raw, &mut frame, core::ptr::null_mut(), 0, core::ptr::null_mut())
		})?;
		let out = unsafe { crate::owned_from_view(frame.bytes, frame.len) };
		unsafe { crate::sys::pancake_managed_frame_release(&mut frame) };
		Ok(out)
	}

	/// Write one frame's bytes into the partner's pipe.
	pub fn write_frame(&mut self, bytes: &[u8]) -> Result<()> {
		let f = crate::sys::PancakeFrame {
			bytes: bytes.as_ptr(),
			len: bytes.len(),
			shape: crate::sys::FRAME_SHAPE_BYTE,
		};
		check_inproc(unsafe {
			ffi::pancake_inproc_conn_write_frame(self.raw, &f, core::ptr::null_mut(), 0, core::ptr::null_mut())
		})
	}
}

// SAFETY: a `Connection` owns a self-contained payload — its own in-process pipe
// half plus a copy of the netlayer's allocator — and shares no per-handle
// mutable state with the netlayer or sibling handles, so moving it to another
// thread and doing frame I/O on it touches only its own state. The allocator and
// the switchboard/`std.Io.Threaded` backend it shares are thread-safe under the
// concurrent blocking calls a borrowed handle makes off-thread (see `Listener`
// above).
unsafe impl Send for Connection<'_> {}

impl Drop for Connection<'_> {
	fn drop(&mut self) {
		unsafe { ffi::pancake_inproc_conn_release(self.raw) };
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::Codec;

	// Two peers wired by an in-process pipe — no socket — shuttle one whole
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
	// own diagnostic, read from `pancake_inproc_last_error` rather than the
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
