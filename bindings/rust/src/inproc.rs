//! The blocking in-process transport (the `inproc` feature).
//!
//! This module wraps `libpancake_net_transport_inproc` — the `pancake_inproc_*`
//! archive that the `inproc` Cargo feature links (ADR-0059). It is the
//! socket-free sibling of [`tcp`](crate::tcp): two peers in one process are
//! wired by in-process pipes, with no kernel transport and no file descriptors.
//! A [`Listener`] binds to a string designator (any opaque token, not a
//! `host:port`) and a dialer names that designator; otherwise the frame shuttle
//! is identical — an [`Endpoint`] reads and writes one whole CapTP frame at a
//! time, and the frame methods block.
//!
//! Errors from a `pancake_inproc_*` call route through the transport archive's
//! own thread-local last-error
//! ([`pancake_inproc_last_error`](crate::sys::inproc::pancake_inproc_last_error)),
//! never the ocapn family's [`last_error`](crate::last_error).

use core::marker::PhantomData;

use crate::sys::inproc as ffi;
use crate::{Codec, Context, Error, Result};

// Like the core `check`, but for `pancake_inproc_*` calls: snapshot the
// in-process transport's own thread-local last-error.
fn check_inproc(code: i32) -> Result<()> {
	if code == crate::sys::OK {
		Ok(())
	} else {
		Err(Error::with_transport_detail(code, inproc_last_error()))
	}
}

/// The calling thread's last error message from the in-process transport archive
/// (`libpancake_net_transport_inproc`), or `None` if none is set. The transport
/// keeps its own thread-local slot, so an inproc call's diagnostic is read here
/// and never from the ocapn family's [`last_error`](crate::last_error).
fn inproc_last_error() -> Option<String> {
	let len = unsafe { ffi::pancake_inproc_last_error(core::ptr::null_mut(), 0) };
	if len == 0 {
		return None;
	}
	let mut buf = vec![0u8; len + 1];
	let written = unsafe { ffi::pancake_inproc_last_error(buf.as_mut_ptr(), buf.len()) };
	buf.truncate(written.min(buf.len()));
	Some(String::from_utf8_lossy(&buf).into_owned())
}

/// Owns the in-process switchboard and its one I/O backend. Connections and
/// listeners borrow it (via `&self`), so the borrow checker rejects an
/// [`Endpoint`] or [`Listener`] that outlives the netlayer that produced it. The
/// `'ctx` lifetime additionally ties a context-backed netlayer to its
/// [`Context`]; a netlayer on the library-owned allocator is `Netlayer<'static>`.
pub struct Netlayer<'ctx> {
	raw: *mut ffi::PancakeInprocNetlayer,
	_ctx: PhantomData<&'ctx Context>,
}

impl<'ctx> Netlayer<'ctx> {
	pub fn new() -> Result<Netlayer<'ctx>> {
		let mut raw: *mut ffi::PancakeInprocNetlayer = core::ptr::null_mut();
		check_inproc(unsafe { ffi::pancake_inproc_netlayer_new(&mut raw) })?;
		Ok(Netlayer {
			raw,
			_ctx: PhantomData,
		})
	}

	/// Create a netlayer whose switchboard, backend, and per-connection buffers
	/// allocate through `context`. The context must outlive the netlayer, which
	/// `'ctx` enforces.
	pub fn new_in(context: &'ctx Context) -> Result<Netlayer<'ctx>> {
		let mut raw: *mut ffi::PancakeInprocNetlayer = core::ptr::null_mut();
		check_inproc(unsafe { ffi::pancake_inproc_netlayer_new_in(context.raw, &mut raw) })?;
		Ok(Netlayer {
			raw,
			_ctx: PhantomData,
		})
	}

	/// Bind an in-process listener on `designator` (any opaque token). The
	/// returned listener borrows this netlayer and cannot outlive it.
	pub fn listen(&self, designator: &str) -> Result<Listener<'_>> {
		let mut raw: *mut ffi::PancakeInprocListener = core::ptr::null_mut();
		check_inproc(unsafe {
			ffi::pancake_inproc_listen(self.raw, designator.as_ptr(), designator.len(), &mut raw)
		})?;
		Ok(Listener {
			raw,
			_nl: PhantomData,
		})
	}

	/// Dial the listener bound at `designator`, framing on `codec` with an
	/// inbound cap of `max_frame_bytes`. The returned connection borrows this
	/// netlayer and cannot outlive it.
	pub fn connect(
		&self,
		designator: &str,
		codec: Codec,
		max_frame_bytes: usize,
	) -> Result<Endpoint<'_>> {
		let mut raw: *mut ffi::PancakeInprocConn = core::ptr::null_mut();
		check_inproc(unsafe {
			ffi::pancake_inproc_connect(
				self.raw,
				designator.as_ptr(),
				designator.len(),
				codec.to_c(),
				max_frame_bytes,
				&mut raw,
			)
		})?;
		Ok(Endpoint {
			raw,
			_nl: PhantomData,
		})
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
	_nl: PhantomData<&'a ()>,
}

impl Listener<'_> {
	/// Block until a dialer connects. The returned connection borrows this
	/// listener (and thus the netlayer) and cannot outlive it.
	pub fn accept(&self, codec: Codec, max_frame_bytes: usize) -> Result<Endpoint<'_>> {
		let mut raw: *mut ffi::PancakeInprocConn = core::ptr::null_mut();
		check_inproc(unsafe {
			ffi::pancake_inproc_accept(self.raw, codec.to_c(), max_frame_bytes, &mut raw)
		})?;
		Ok(Endpoint {
			raw,
			_nl: PhantomData,
		})
	}
}

// A listener handle is safe to move to the accepting thread (use a scoped
// thread, since it borrows the netlayer and so is not `'static`).
unsafe impl Send for Listener<'_> {}

impl Drop for Listener<'_> {
	fn drop(&mut self) {
		unsafe { ffi::pancake_inproc_listener_release(self.raw) };
	}
}

/// A blocking in-process endpoint, the `pancake_inproc_*` frame shuttle.
/// Closed on drop. The frame methods block. Borrows the [`Netlayer`] (or
/// [`Listener`]) it came from, so that backend outlives it.
pub struct Endpoint<'a> {
	raw: *mut ffi::PancakeInprocConn,
	_nl: PhantomData<&'a ()>,
}

impl Endpoint<'_> {
	/// Block for one whole frame. An error with `code() == -8` is a clean EOF.
	pub fn read_frame(&mut self) -> Result<Vec<u8>> {
		let mut frame: crate::sys::PancakeManagedFrame = unsafe { core::mem::zeroed() };
		check_inproc(unsafe { ffi::pancake_inproc_conn_read_frame(self.raw, &mut frame) })?;
		let out = unsafe { core::slice::from_raw_parts(frame.bytes, frame.len) }.to_vec();
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
		check_inproc(unsafe { ffi::pancake_inproc_conn_write_frame(self.raw, &f) })
	}
}

unsafe impl Send for Endpoint<'_> {}

impl Drop for Endpoint<'_> {
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
		// `Endpoint` is not `Debug` (an opaque connection handle), so match
		// rather than `unwrap_err`. The diagnostic comes from the inproc
		// transport's own last-error slot via `check_inproc`.
		let dialed = netlayer.connect("nobody-home", Codec::Syrup, 4096);
		match dialed {
			Ok(_) => panic!("dialing an unbound designator should fail"),
			Err(err) => assert_ne!(err.code(), crate::sys::OK),
		}
	}
}
