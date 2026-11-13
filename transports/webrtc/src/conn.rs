//! The C-facing connection surface: peer identity and open state, blocking
//! and non-blocking reads and writes, and the close/free release pair.

use super::*;

/// Stable endpoint-scoped identity carried by readiness records. Returns zero
/// for an invalid handle. Live peers are always nonzero.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_peer_id(peer: *const GlowcapWebrtcPeer) -> usize {
	// SAFETY: the handle contract `borrowed` states.
	unsafe { borrowed(peer, 0, |peer| peer.shared.id) }
}

/// Non-blocking channel-open check: `OK` once open, `WOULD_BLOCK` while the
/// signaling/ICE/DTLS/SCTP establishment is still in progress, `CLOSED` after
/// clean close, or `ERR` after setup failure.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_peer_is_open(peer: *const GlowcapWebrtcPeer) -> i32 {
	// SAFETY: the handle contract `borrowed` states.
	unsafe { borrowed(peer, ERR, |peer| open_result(&peer.shared.open.lock().unwrap())) }
}

/// Non-blocking receive for readiness owners. Returns one packet, zero at clean
/// EOF, `WOULD_BLOCK` when no packet is buffered yet, `BUFFER_TOO_SMALL` when
/// the packet remains queued for a larger buffer, or `ERR` on invalid input.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_conn_try_receive_packet(
	peer: *mut GlowcapWebrtcPeer,
	buf: *mut u8,
	len: usize,
) -> isize {
	// The body stays outside the `unsafe` block below so its own raw-buffer
	// projection is still marked where it happens, rather than absorbed into
	// the handle's block.
	let receive = |peer: &GlowcapWebrtcPeer| {
		if buf.is_null() || len == 0 {
			return ERR as isize;
		}
		let mut guard = peer.shared.inbound.0.lock().unwrap();
		if guard.packets.is_empty() {
			return terminal_read_result(&guard);
		}
		// SAFETY: the caller's contract is `len` writable bytes at `buf`, and
		// the null and zero-length cases were refused above.
		let dst = unsafe { std::slice::from_raw_parts_mut(buf, len) };
		let n = take_inbound_packet(&mut guard, dst);
		drop(guard);
		if n > 0 {
			peer.shared.drained.notify_one();
		}
		n
	};
	// SAFETY: the handle contract `borrowed` states.
	unsafe { borrowed(peer, ERR as isize, receive) }
}

/// Non-blocking send for readiness owners. The call copies one whole packet
/// into the bounded sidecar staging buffer and returns immediately, without
/// entering the async runtime. `WOULD_BLOCK` means no sidecar capacity is
/// available, so re-arm on `EV_WRITABLE` and retry the same packet. An ended
/// channel admits nothing: `CLOSED` after a clean close, `ERR` after a failure.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_conn_try_send_packet(
	peer: *mut GlowcapWebrtcPeer,
	buf: *const u8,
	len: usize,
) -> isize {
	// Outside the `unsafe` block below, so the caller-buffer projection is still
	// marked where it happens rather than absorbed into the handle's block.
	let send = |peer: &GlowcapWebrtcPeer| {
		if buf.is_null() || len > isize::MAX as usize {
			return ERR as isize;
		}
		// SAFETY: the caller's contract is `len` readable bytes at `buf`, and
		// the null and oversized cases went to the arm above.
		let bytes = unsafe { std::slice::from_raw_parts(buf, len) };
		try_send(&peer.shared, bytes)
	};
	// SAFETY: the handle contract `borrowed` states.
	unsafe { borrowed(peer, ERR as isize, send) }
}

/// Close the channel, waking any packet receiver with end of stream.
/// Idempotent. `peer_free` still frees the handle afterward.
///
/// # Safety
/// `peer` must be a live pointer from `peer_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_conn_close(peer: *mut GlowcapWebrtcPeer) {
	// SAFETY: the caller's contract above, a live pointer from `peer_new`.
	let peer = match unsafe { peer.as_ref() } {
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
/// `peer` must have come from `peer_new` and not been freed. Null is ignored.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_peer_free(peer: *mut GlowcapWebrtcPeer) {
	// SAFETY: the caller's contract above makes `peer` null or an unfreed pointer from `peer_new`, and `as_ref` maps
	// null to `None`. The borrow ends with this statement.
	let Some(failures) = (unsafe { peer.as_ref() }).map(|peer| peer.shared.endpoint.close_tasks.clone()) else {
		return;
	};
	// SAFETY: the caller transfers the peer, and the failure-slot borrow has ended.
	if unsafe {
		reclaimed(peer, |peer| {
			// Same ordering as `conn_close`: free a parked poller before closing.
			publish_peer_closed(&peer.shared);
			close_peer_async(&peer);
			// `peer` drops here; the endpoint owns the shared runtime.
			Ok::<(), core::convert::Infallible>(())
		})
	} != 0
	{
		failures.record_failure();
	}
}
