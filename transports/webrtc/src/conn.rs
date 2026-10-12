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

pub(crate) fn open_result(gate: &OpenGate) -> i32 {
	if gate.closed {
		return if gate.failed { ERR } else { CLOSED };
	}
	if gate.open { OK } else { WOULD_BLOCK }
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
/// available, so re-arm on `EV_WRITABLE` and retry the same packet.
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
		if !peer.shared.open.lock().unwrap().open {
			return WOULD_BLOCK as isize;
		}
		if len == 0 {
			return 0;
		}
		if peer.shared.dc.lock().unwrap().is_none() {
			return WOULD_BLOCK as isize;
		}
		// SAFETY: the caller's contract is `len` readable bytes at `buf`, and
		// the null, oversized, and zero-length cases went to the arms above.
		let bytes = unsafe { std::slice::from_raw_parts(buf, len) };
		let accepted = {
			let mut outbound = peer.shared.outbound.lock().unwrap();
			enqueue_outbound(&mut outbound, bytes)
		};
		if accepted > 0 {
			peer.shared.outbound_ready.notify_one();
		}
		accepted
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
	if peer.is_null() {
		return;
	}
	// SAFETY: the caller's contract above, an unfreed pointer from `peer_new`,
	// with null already refused, so this frame is its last owner.
	let failures = unsafe { peer.as_ref() }.unwrap().shared.endpoint.close_tasks.clone();
	if catch_unwind(AssertUnwindSafe(|| {
		// SAFETY: `peer` is non-null (checked above) and, per this function's `# Safety` contract, the unfreed pointer
		// `peer_new` boxed with `Box::into_raw`; the `as_ref` borrow above ended with that statement, so this frame is
		// its last owner and takes back the one allocation.
		let peer = unsafe { Box::from_raw(peer) };
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
