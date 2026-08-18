//! The C-facing connection surface: peer identity and open state, blocking
//! and non-blocking reads and writes, and the close/free release pair.

use super::*;

/// Stable endpoint-scoped identity carried by readiness records. Returns zero
/// for an invalid handle; live peers are always nonzero.
#[no_mangle]
pub unsafe extern "C" fn pancake_webrtc_sidecar_peer_id(peer: *const PancakeWebrtcPeer) -> usize {
	catch_unwind(AssertUnwindSafe(|| {
		peer.as_ref().map(|peer| peer.shared.id).unwrap_or(0)
	}))
	.unwrap_or(0)
}

/// Non-blocking channel-open check: `OK` once open, `WOULD_BLOCK` while the
/// signaling/ICE/DTLS/SCTP establishment is still in progress, `ERR` if closed.
#[no_mangle]
pub unsafe extern "C" fn pancake_webrtc_sidecar_peer_is_open(peer: *const PancakeWebrtcPeer) -> i32 {
	catch_unwind(AssertUnwindSafe(|| {
		let peer = match peer.as_ref() {
			Some(peer) => peer,
			None => return ERR,
		};
		let gate = peer.shared.open.lock().unwrap();
		if gate.closed {
			return ERR;
		}
		if gate.open {
			OK
		} else {
			WOULD_BLOCK
		}
	}))
	.unwrap_or(ERR)
}

/// Blocking read of session bytes off the data channel into `(buf, len)`. Parks
/// the caller's own thread on the inbound condvar until bytes arrive; returns
/// the count read (> 0), `0` at clean end of stream, or `ERR`.
///
/// # Safety
/// `peer` live; `buf` points to `len` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn pancake_webrtc_sidecar_conn_read(
	peer: *mut PancakeWebrtcPeer,
	buf: *mut u8,
	len: usize,
) -> isize {
	catch_unwind(AssertUnwindSafe(|| {
		let peer = match peer.as_ref() {
			Some(peer) => peer,
			None => return ERR as isize,
		};
		if buf.is_null() || len == 0 {
			return ERR as isize;
		}
		let (lock, cvar) = &*peer.shared.inbound;
		let mut guard = lock.lock().unwrap();
		while guard.buf.is_empty() && !guard.closed {
			guard = cvar.wait(guard).unwrap();
		}
		if guard.buf.is_empty() {
			return 0; // closed, drained
		}
		// The C ABI exposes a contiguous read buffer while WebRTC delivers
		// message-owned storage. Copy the staging deque's (up to two) contiguous
		// runs in bulk, then drop the drained prefix, rather than popping a byte
		// at a time.
		let dst = std::slice::from_raw_parts_mut(buf, len);
		let n = take_inbound(&mut guard, dst);
		drop(guard);
		peer.shared.drained.notify_one();
		n as isize
	}))
	.unwrap_or(ERR as isize)
}

/// Non-blocking read for readiness owners. Returns bytes, zero at clean EOF,
/// `WOULD_BLOCK` when no bytes are buffered yet, or `ERR` on invalid input.
#[no_mangle]
pub unsafe extern "C" fn pancake_webrtc_sidecar_conn_try_read(
	peer: *mut PancakeWebrtcPeer,
	buf: *mut u8,
	len: usize,
) -> isize {
	catch_unwind(AssertUnwindSafe(|| {
		let peer = match peer.as_ref() {
			Some(peer) => peer,
			None => return ERR as isize,
		};
		if buf.is_null() || len == 0 {
			return ERR as isize;
		}
		let mut guard = peer.shared.inbound.0.lock().unwrap();
		if guard.buf.is_empty() {
			return if guard.closed { 0 } else { WOULD_BLOCK as isize };
		}
		let dst = std::slice::from_raw_parts_mut(buf, len);
		let n = take_inbound(&mut guard, dst);
		drop(guard);
		peer.shared.drained.notify_one();
		n as isize
	}))
	.unwrap_or(ERR as isize)
}

/// Non-blocking write for readiness owners. The call copies into the bounded
/// sidecar staging buffer and returns immediately, without entering the async
/// runtime. A successful call may admit a prefix; the caller advances by the
/// returned count. `WOULD_BLOCK` means no sidecar capacity is available, so
/// re-arm on `EV_WRITABLE`.
#[no_mangle]
pub unsafe extern "C" fn pancake_webrtc_sidecar_conn_try_write(
	peer: *mut PancakeWebrtcPeer,
	buf: *const u8,
	len: usize,
) -> isize {
	catch_unwind(AssertUnwindSafe(|| {
		let peer = match peer.as_ref() {
			Some(peer) => peer,
			None => return ERR as isize,
		};
		if buf.is_null() || len > isize::MAX as usize {
			return ERR as isize;
		}
		if !peer.shared.open.lock().unwrap().open {
			return WOULD_BLOCK as isize;
		}
		if len == 0 {
			return 0;
		}
		if peer.shared.dc.lock().unwrap().is_none() {
			return WOULD_BLOCK as isize;
		}
		let bytes = std::slice::from_raw_parts(buf, len);
		let accepted = {
			let mut outbound = peer.shared.outbound.lock().unwrap();
			enqueue_outbound(&mut outbound, bytes)
		};
		if accepted > 0 {
			peer.shared.outbound_ready.notify_one();
		}
		accepted
	}))
	.unwrap_or(ERR as isize)
}

/// Write session bytes to the data channel. Returns `len` on success, `ERR` if
/// the channel is not yet present or the send fails.
///
/// # Safety
/// `peer` live; `buf` points to `len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn pancake_webrtc_sidecar_conn_write(
	peer: *mut PancakeWebrtcPeer,
	buf: *const u8,
	len: usize,
) -> isize {
	catch_unwind(AssertUnwindSafe(|| {
		let peer = match peer.as_ref() {
			Some(peer) => peer,
			None => return ERR as isize,
		};
		if buf.is_null() {
			return ERR as isize;
		}
		let dc = match peer.shared.dc.lock().unwrap().clone() {
			Some(dc) => dc,
			None => return ERR as isize,
		};
		let src = std::slice::from_raw_parts(buf, len);
		let sent = peer.shared.endpoint.runtime().block_on(async {
			let mut offset = 0usize;
			while offset < src.len() {
				let next = (src.len() - offset).min(STEADY_BUFFER_BYTES);
				dc.send(BytesMut::from(&src[offset..offset + next])).await?;
				offset += next;
			}
			Ok::<(), WebrtcError>(())
		});
		match sent {
			Ok(()) => len as isize,
			Err(_) => {
				publish_peer_closed(&peer.shared);
				ERR as isize
			}
		}
	}))
	.unwrap_or(ERR as isize)
}

/// Close the channel and connection, waking any parked reader with end of
/// stream. Idempotent; `peer_free` still frees the handle afterward.
///
/// # Safety
/// `peer` must be a live pointer from `peer_new`.
#[no_mangle]
pub unsafe extern "C" fn pancake_webrtc_sidecar_conn_close(peer: *mut PancakeWebrtcPeer) {
	let peer = match peer.as_ref() {
		Some(peer) => peer,
		None => return,
	};
	let failures = peer.shared.endpoint.close_tasks.clone();
	if catch_unwind(AssertUnwindSafe(|| {
		// Release a poller parked for room first. Nobody will drain the
		// buffer now, and closing while a runtime task still holds a message
		// makes shutdown depend on the crate's internals to make progress.
		publish_peer_closed(&peer.shared);
		close_peer_async(peer);
	}))
	.is_err()
	{
		failures.record_failure();
	}
}

/// Free a peer created by `peer_new`, closing its connection and releasing its
/// reference to the endpoint-owned runtime.
///
/// # Safety
/// `peer` must have come from `peer_new` and not been freed; null is ignored.
#[no_mangle]
pub unsafe extern "C" fn pancake_webrtc_sidecar_peer_free(peer: *mut PancakeWebrtcPeer) {
	if peer.is_null() {
		return;
	}
	let failures = peer.as_ref().unwrap().shared.endpoint.close_tasks.clone();
	if catch_unwind(AssertUnwindSafe(|| {
		let peer = Box::from_raw(peer);
		// Same ordering as `conn_close`: free a parked poller before closing.
		publish_peer_closed(&peer.shared);
		close_peer_async(&peer);
		// `peer` drops here; the endpoint owns the shared runtime.
	}))
	.is_err()
	{
		failures.record_failure();
	}
}
