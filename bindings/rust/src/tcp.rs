//! The blocking TCP transport (the `tcp` feature).
//!
//! This module wraps `libpancake_net_transport_tcp` — the `pancake_tcp_*`
//! archive that the `tcp` Cargo feature links (ADR-0059). It is the
//! frame-shuttle layer one step below the async [`Connection`](crate::Connection):
//! a [`Netlayer`] owns the blocking-TCP I/O backend, [`Netlayer::listen`] /
//! [`Netlayer::connect`] bind and dial, and an [`Endpoint`] reads and writes one
//! whole CapTP frame at a time. The frame methods block.
//!
//! Errors from a `pancake_tcp_*` call route through the transport archive's own
//! thread-local last-error (`pancake_tcp_last_error`),
//! never the ocapn family's [`last_error`](crate::last_error).

use core::marker::PhantomData;

use crate::error_slot::error_slot;
use crate::sys::tcp as ffi;
use crate::{Codec, Context, Result};

error_slot!(
	// Like the core `check`, but for `pancake_tcp_*` calls: snapshot the TCP
	// transport's own thread-local last-error rather than the unrelated
	// ocapn-family one.
	fn check_tcp;
	fn tcp_last_error;
	ffi::pancake_tcp_last_error
);

/// Owns the blocking-TCP I/O backend. Connections and listeners borrow it (via
/// `&self`), so the borrow checker rejects an [`Endpoint`] or [`Listener`] that
/// outlives the netlayer that produced it. The `'ctx` lifetime additionally ties
/// a context-backed netlayer to its [`Context`]; a netlayer on the library-owned
/// allocator is `Netlayer<'static>`.
///
/// A connection cannot outlive the netlayer that produced it:
///
/// ```compile_fail
/// use pancake_rust_dogfood::{Codec, tcp::Netlayer};
/// let _conn = {
///     let netlayer = Netlayer::new().unwrap();
///     netlayer.connect("127.0.0.1", 1, Codec::Syrup, 4096).unwrap()
/// }; // netlayer is dropped here, so the borrow checker rejects keeping the conn.
/// ```
pub struct Netlayer<'ctx> {
	raw: *mut ffi::PancakeTcpNetlayer,
	_ctx: PhantomData<&'ctx Context>,
}

impl<'ctx> Netlayer<'ctx> {
	pub fn new() -> Result<Netlayer<'ctx>> {
		let mut raw: *mut ffi::PancakeTcpNetlayer = core::ptr::null_mut();
		check_tcp(unsafe { ffi::pancake_tcp_netlayer_new(&mut raw) })?;
		Ok(Netlayer {
			raw,
			_ctx: PhantomData,
		})
	}

	/// Create a netlayer whose backend and per-connection buffers allocate through
	/// `context`. The context must outlive the netlayer, which `'ctx` enforces.
	pub fn new_in(context: &'ctx Context) -> Result<Netlayer<'ctx>> {
		let mut raw: *mut ffi::PancakeTcpNetlayer = core::ptr::null_mut();
		check_tcp(unsafe { ffi::pancake_tcp_netlayer_new_in(context.raw, &mut raw) })?;
		Ok(Netlayer {
			raw,
			_ctx: PhantomData,
		})
	}

	/// Bind and listen on `host:port` (port 0 = OS-chosen). The returned listener
	/// borrows this netlayer and cannot outlive it.
	pub fn listen(&self, host: &str, port: u16) -> Result<Listener<'_>> {
		let mut raw: *mut ffi::PancakeTcpListener = core::ptr::null_mut();
		check_tcp(unsafe {
			ffi::pancake_tcp_listen(self.raw, host.as_ptr(), host.len(), port, &mut raw)
		})?;
		Ok(Listener {
			raw,
			_nl: PhantomData,
		})
	}

	/// Connect to `host:port`, framing on `codec` with an inbound cap of
	/// `max_frame_bytes`. The returned connection borrows this netlayer and
	/// cannot outlive it.
	pub fn connect(
		&self,
		host: &str,
		port: u16,
		codec: Codec,
		max_frame_bytes: usize,
	) -> Result<Endpoint<'_>> {
		let mut raw: *mut ffi::PancakeTcpConn = core::ptr::null_mut();
		check_tcp(unsafe {
			ffi::pancake_tcp_connect(
				self.raw,
				host.as_ptr(),
				host.len(),
				port,
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
		unsafe { ffi::pancake_tcp_netlayer_release(self.raw) };
	}
}

/// A bound listener. Released on drop. Borrows the [`Netlayer`] it came from, so
/// the netlayer outlives every accepted connection.
pub struct Listener<'a> {
	raw: *mut ffi::PancakeTcpListener,
	_nl: PhantomData<&'a ()>,
}

impl Listener<'_> {
	/// The OS-resolved local port (useful after binding to port 0).
	pub fn port(&self) -> Result<u16> {
		let mut port: u16 = 0;
		check_tcp(unsafe { ffi::pancake_tcp_listener_port(self.raw, &mut port) })?;
		Ok(port)
	}

	/// Block for a client connection. The returned connection borrows this
	/// listener (and thus the netlayer) and cannot outlive it.
	pub fn accept(&self, codec: Codec, max_frame_bytes: usize) -> Result<Endpoint<'_>> {
		let mut raw: *mut ffi::PancakeTcpConn = core::ptr::null_mut();
		check_tcp(unsafe {
			ffi::pancake_tcp_accept(self.raw, codec.to_c(), max_frame_bytes, &mut raw)
		})?;
		Ok(Endpoint {
			raw,
			_nl: PhantomData,
		})
	}
}

// SAFETY: a `Listener` owns a self-contained payload — its own listening socket
// plus a copy of the netlayer's allocator — and shares no per-handle mutable
// state with the netlayer or sibling handles, so moving it to the accepting
// thread and calling `accept` there touches only its own state. The two pieces
// it does share with the netlayer are both thread-safe: the allocator
// (`std.heap.smp_allocator` for `Netlayer::new`, or a bounded `Send + Sync`
// `HostAllocator` for `new_in`) and the netlayer's `std.Io.Threaded` backend,
// which tolerates the concurrent blocking calls a borrowed handle on one thread
// makes while the netlayer is used on the origin. Borrowing the netlayer keeps
// it non-`'static`, so callers move it into a scoped thread.
unsafe impl Send for Listener<'_> {}

impl Drop for Listener<'_> {
	fn drop(&mut self) {
		unsafe { ffi::pancake_tcp_listener_release(self.raw) };
	}
}

/// A blocking TCP endpoint, the `pancake_tcp_*` frame shuttle, one
/// layer below [`Connection`](crate::Connection). Closed on drop. The frame
/// methods block. Borrows the [`Netlayer`] (or [`Listener`]) it came from, so
/// that backend outlives it.
pub struct Endpoint<'a> {
	raw: *mut ffi::PancakeTcpConn,
	_nl: PhantomData<&'a ()>,
}

impl Endpoint<'_> {
	/// Block for one whole frame. An error with `code() == -8` is a clean EOF.
	pub fn read_frame(&mut self) -> Result<Vec<u8>> {
		let mut frame: crate::sys::PancakeManagedFrame = unsafe { core::mem::zeroed() };
		check_tcp(unsafe { ffi::pancake_tcp_conn_read_frame(self.raw, &mut frame) })?;
		let out = unsafe { crate::owned_from_view(frame.bytes, frame.len) };
		unsafe { crate::sys::pancake_managed_frame_release(&mut frame) };
		Ok(out)
	}

	/// Write one frame's bytes and flush.
	pub fn write_frame(&mut self, bytes: &[u8]) -> Result<()> {
		let f = crate::sys::PancakeFrame {
			bytes: bytes.as_ptr(),
			len: bytes.len(),
			shape: crate::sys::FRAME_SHAPE_BYTE,
		};
		check_tcp(unsafe { ffi::pancake_tcp_conn_write_frame(self.raw, &f) })
	}
}

// SAFETY: an `Endpoint` owns a self-contained payload — its own TCP stream plus
// a copy of the netlayer's allocator — and shares no per-handle mutable state
// with the netlayer or sibling handles, so moving it to another thread and doing
// frame I/O on it touches only its own state. The allocator and the netlayer's
// `std.Io.Threaded` backend it shares are thread-safe under the concurrent
// blocking calls a borrowed handle makes off-thread (see `Listener` above).
unsafe impl Send for Endpoint<'_> {}

impl Drop for Endpoint<'_> {
	fn drop(&mut self) {
		unsafe { ffi::pancake_tcp_conn_release(self.raw) };
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::Codec;

	#[test]
	fn shuttles_a_frame_over_a_real_tcp_socket() {
		// The netlayer owns the I/O backend; the listener and connections borrow
		// it, so a scoped thread keeps those borrows honest (the borrowed
		// `Listener` is not `'static` and cannot enter `thread::spawn`).
		let netlayer = Netlayer::new().unwrap();
		let listener = netlayer.listen("127.0.0.1", 0).unwrap();
		let port = listener.port().unwrap();

		let received = std::thread::scope(|scope| {
			let server = scope.spawn(move || {
				let mut conn = listener.accept(Codec::Syrup, 4096).unwrap();
				conn.read_frame().unwrap()
			});

			let mut client = netlayer
				.connect("127.0.0.1", port, Codec::Syrup, 4096)
				.unwrap();
			client.write_frame(b"<8'op:abort3\"bye>").unwrap();

			server.join().unwrap()
		});
		assert_eq!(received, b"<8'op:abort3\"bye>");
	}

	// A whole-frame round-trip over the blocking TCP transport: the server
	// reads the client's frame, answers with its own, and the client reads it
	// back, proving the `tcp` archive delimits and shuttles whole frames in
	// both directions. The frames are canned protocol bytes; the transport
	// archive owns framing, never dispatch.
	#[test]
	fn shuttles_whole_frames_in_both_directions_over_tcp() {
		const QUESTION: &[u8] =
			b"<10'op:deliver<11'desc:export7+>[5:hello]11+<19'desc:import-promise99+>>";
		const ANSWER: &[u8] = b"<8'op:abort7\"replied>";

		let netlayer = Netlayer::new().unwrap();
		let listener = netlayer.listen("127.0.0.1", 0).unwrap();
		let port = listener.port().unwrap();

		let reply = std::thread::scope(|scope| {
			let server = scope.spawn(move || {
				let mut conn = listener.accept(Codec::Syrup, 4096).unwrap();
				let frame = conn.read_frame().unwrap();
				assert_eq!(frame, QUESTION);
				conn.write_frame(ANSWER).unwrap();
			});

			let mut client = netlayer
				.connect("127.0.0.1", port, Codec::Syrup, 4096)
				.unwrap();
			client.write_frame(QUESTION).unwrap();
			let frame = client.read_frame().unwrap();
			server.join().unwrap();
			frame
		});
		assert_eq!(reply, ANSWER);
	}
}
