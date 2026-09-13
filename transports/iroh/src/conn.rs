//! The blocking per-connection surface: remote identity, read, write,
//! flush, and the close/free release pair every ownership mode funnels into.

use super::*;

fn ffi_len(len: usize) -> Option<isize> {
	isize::try_from(len).ok()
}

/// Write the connection's QUIC-authenticated remote endpoint id — the 32-byte
/// Ed25519 public key TLS verified during the handshake — into `out_key32`.
/// This is the transport-layer peer proof the driver installs as pre-feed
/// CapTP hello policy on accept paths (ADR-0097); a dial already carries the
/// same guarantee, since iroh refuses to connect to any endpoint but the id
/// it was asked for. Returns 0 on success, -1 on failure. Borrows the handle.
///
/// # Safety
/// `conn` must be null or a live connection handle; `out_key32` must be null
/// or address 32 writable bytes. Null pointers are refused.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_iroh_sidecar_conn_remote_node_id(
	conn: *const GlowcapIrohConn,
	out_key32: *mut u8,
) -> i32 {
	if conn.is_null() || out_key32.is_null() {
		return -1;
	}
	let result = catch_unwind(AssertUnwindSafe(|| {
		// SAFETY: upheld by the caller after the null check above.
		let conn = unsafe { &*conn };
		*conn.conn.remote_id().as_bytes()
	}));
	match result {
		Ok(bytes) => {
			// SAFETY: upheld by the caller; the source is exactly 32 bytes.
			unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out_key32, 32) };
			0
		}
		Err(_) => -1,
	}
}

/// Read up to `len` bytes from the stream into `buf`, blocking until at least
/// one byte arrives. Returns the byte count (> 0), 0 at clean end of stream
/// (the partner finished its send side or closed the connection cleanly), or
/// -1 on error. Borrows the handle.
///
/// # Safety
/// `conn` must be null or a live connection handle. For nonzero `len`, `buf` must
/// address `len` writable bytes. Null pointers and unrepresentable lengths are
/// refused defensively; a zero-length read does not dereference `buf`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_iroh_sidecar_conn_read(conn: *mut GlowcapIrohConn, buf: *mut u8, len: usize) -> isize {
	if conn.is_null() {
		return -1;
	}
	if len == 0 {
		return 0;
	}
	if buf.is_null() || ffi_len(len).is_none() {
		return -1;
	}
	let result = catch_unwind(AssertUnwindSafe(|| {
		// SAFETY: upheld by the caller after the pointer and length checks above.
		let conn = unsafe { &*conn };
		let dest = unsafe { std::slice::from_raw_parts_mut(buf, len) };
		let mut guard = match conn.recv.lock() {
			Ok(guard) => guard,
			Err(_) => return -1,
		};
		// The stream was moved into the reader task by `conn_set_nonblocking`;
		// the blocking read is no longer this caller's to make.
		let recv = match guard.as_mut() {
			Some(recv) => recv,
			None => return -1,
		};
		use iroh::endpoint::{ConnectionError, ReadError};
		match conn.rt.block_on(recv.read(dest)) {
			Ok(Some(n)) => isize::try_from(n).unwrap_or(-1),
			Ok(None) => 0,
			// A clean connection-level close is end-of-stream, not a fault.
			Err(ReadError::ConnectionLost(ConnectionError::ApplicationClosed(_)))
			| Err(ReadError::ConnectionLost(ConnectionError::LocallyClosed)) => 0,
			Err(_) => -1,
		}
	}));
	result.unwrap_or(-1)
}

/// Write all `len` bytes from `buf` to the stream, blocking until accepted by
/// the QUIC flow-control window. Returns `len`, or -1 on error. Borrows the
/// handle.
///
/// # Safety
/// `conn` must be null or a live connection handle. For nonzero `len`, `buf` must
/// address `len` readable bytes. Null pointers and unrepresentable lengths are
/// refused defensively; a zero-length write does not dereference `buf`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_iroh_sidecar_conn_write(
	conn: *mut GlowcapIrohConn,
	buf: *const u8,
	len: usize,
) -> isize {
	if conn.is_null() {
		return -1;
	}
	if len == 0 {
		return 0;
	}
	let Some(written) = ffi_len(len) else {
		return -1;
	};
	if buf.is_null() {
		return -1;
	}
	let result = catch_unwind(AssertUnwindSafe(|| {
		// SAFETY: upheld by the caller after the pointer and length checks above.
		let conn = unsafe { &*conn };
		let src = unsafe { std::slice::from_raw_parts(buf, len) };
		let mut guard = match conn.send.lock() {
			Ok(guard) => guard,
			Err(_) => return -1,
		};
		let send = match guard.as_mut() {
			Some(send) => send,
			None => return -1,
		};
		match conn.rt.block_on(send.write_all(src)) {
			Ok(()) => written,
			Err(_) => -1,
		}
	}));
	result.unwrap_or(-1)
}

/// Report stream health after writes. QUIC transmits written bytes eagerly, so
/// there is no buffered data to push; this returns 0 while the connection is
/// alive and -1 once it is closed or lost. Borrows the handle.
///
/// # Safety
/// `conn` must be null or a live connection handle. Null is refused.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_iroh_sidecar_conn_flush(conn: *mut GlowcapIrohConn) -> i32 {
	if conn.is_null() {
		return -1;
	}
	let result = catch_unwind(AssertUnwindSafe(|| {
		// SAFETY: upheld by the caller after the null check above.
		let conn = unsafe { &*conn };
		if conn.conn.close_reason().is_some() { -1 } else { 0 }
	}));
	result.unwrap_or(-1)
}

/// Gracefully close the connection: finish the send stream (the partner's read
/// sees clean end of stream) and queue a QUIC close. Idempotent; safe to call
/// before `glowcap_iroh_sidecar_conn_free`. Borrows the handle.
///
/// # Safety
/// `conn` must be null or a live connection handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_iroh_sidecar_conn_close(conn: *mut GlowcapIrohConn) {
	if conn.is_null() {
		return;
	}
	let writers = unsafe { &*conn }.writers.clone();
	if catch_unwind(AssertUnwindSafe(|| {
		let conn = unsafe { &*conn };
		// On the readiness surface, ownership has already transferred to the
		// tasks. Let the writer drain every admitted byte and finish its stream;
		// closing the QUIC connection here would discard the final owned batch.
		if let Some(nb) = conn.nb.get() {
			let mut out = nb.outbound.lock().unwrap_or_else(|poisoned| {
				conn.writers.record_failure();
				poisoned.into_inner()
			});
			out.closed = true;
			drop(out);
			nb.close_work.notify_one();
			nb.write_work.notify_one();
			return;
		}
		if let Ok(mut send) = conn.send.try_lock()
			&& let Some(send) = send.as_mut()
		{
			// Best-effort graceful finish, but only when no writer is mid-call:
			// blocking on `send` here would deadlock a writer parked on QUIC
			// flow control, which the `conn.close()` below is what unblocks.
			if send.finish().is_err() {
				conn.writers.record_failure();
			}
		}
		// The compatibility surface may have a thread parked in a blocking call;
		// close the connection to wake it without waiting on its stream lock.
		conn.conn.close(0u32.into(), b"");
	}))
	.is_err()
	{
		writers.record_failure();
	}
}

/// Release a connection handle. Closes the connection if still open. Every
/// connection must be freed before its endpoint.
///
/// Safe to call while another thread is parked in a blocking `conn_read` or
/// `conn_write` on the same handle (the teardown a binding hits when it releases
/// a connection whose inbound loop is still parked on a read): closing the QUIC
/// connection makes the parked call return at once, and acquiring both stream
/// locks before the drop fences against it, once the locks are free, no
/// blocking call is still borrowing this box, so the free below cannot race one.
///
/// # Safety
/// `conn` must be null or an owned connection handle not previously freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_iroh_sidecar_conn_free(conn: *mut GlowcapIrohConn) {
	if conn.is_null() {
		return;
	}
	// Unblock any parked blocking read/write (closes the connection without
	// taking a stream lock, so a writer parked on flow control cannot deadlock).
	// SAFETY: this function holds the same owned live handle contract.
	unsafe { glowcap_iroh_sidecar_conn_close(conn) };
	let nonblocking = unsafe { (&*conn).nb.get().is_some() };
	if !nonblocking {
		let _ = catch_unwind(AssertUnwindSafe(|| {
			let conn_ref = unsafe { &*conn };
			// Fence: wait out an in-flight blocking call. A reader/writer holds
			// `recv`/`send` for the whole `block_on`; once close has unblocked it,
			// acquiring both locks proves the call has returned its borrow. The
			// guards drop at the end of this block, before the box is freed.
			let _recv = conn_ref.recv.lock();
			let _send = conn_ref.send.lock();
		}));
	}
	let writers = unsafe { &*conn }.writers.clone();
	if catch_unwind(AssertUnwindSafe(|| {
		let inner = *unsafe { Box::from_raw(conn) };
		// The reader has no useful work after local release; abort it. The writer
		// owns every byte `conn_try_write` admitted, so detach it. Its writer permit
		// remains the endpoint's explicit barrier before runtime shutdown, without
		// retaining one completed JoinHandle per lifetime connection.
		if let Some((reader, writer)) = inner.nb_tasks.into_inner() {
			reader.abort();
			drop(writer);
		}
	}))
	.is_err()
	{
		writers.record_failure();
	}
}

#[cfg(test)]
mod contract_tests {
	use super::*;

	#[test]
	fn null_blocking_handles_are_refused_without_dereference() {
		unsafe {
			assert_eq!(
				glowcap_iroh_sidecar_conn_remote_node_id(std::ptr::null(), std::ptr::null_mut()),
				-1
			);
			assert_eq!(
				glowcap_iroh_sidecar_conn_read(std::ptr::null_mut(), std::ptr::null_mut(), 1),
				-1
			);
			assert_eq!(
				glowcap_iroh_sidecar_conn_write(std::ptr::null_mut(), std::ptr::null(), 1),
				-1
			);
			assert_eq!(glowcap_iroh_sidecar_conn_flush(std::ptr::null_mut()), -1);
		}
	}

	#[test]
	fn blocking_io_refuses_lengths_outside_isize() {
		let too_large = usize::try_from(isize::MAX).unwrap().checked_add(1).unwrap();
		assert_eq!(ffi_len(0), Some(0));
		assert_eq!(ffi_len(usize::try_from(isize::MAX).unwrap()), Some(isize::MAX));
		assert_eq!(ffi_len(too_large), None);
	}
}
