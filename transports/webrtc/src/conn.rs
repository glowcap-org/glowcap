//! The C-facing connection surface: peer identity and open state, blocking
//! and non-blocking reads and writes, and the close/free release pair.

use super::*;

/// Stable endpoint-scoped identity carried by readiness records. Returns zero
/// for an invalid handle; live peers are always nonzero.
#[no_mangle]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_peer_id(peer: *const GlowcapWebrtcPeer) -> usize {
	catch_unwind(AssertUnwindSafe(|| {
		peer.as_ref().map(|peer| peer.shared.id).unwrap_or(0)
	}))
	.unwrap_or(0)
}

/// Non-blocking channel-open check: `OK` once open, `WOULD_BLOCK` while the
/// signaling/ICE/DTLS/SCTP establishment is still in progress, `CLOSED` after
/// clean close, or `ERR` after setup failure.
#[no_mangle]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_peer_is_open(peer: *const GlowcapWebrtcPeer) -> i32 {
	catch_unwind(AssertUnwindSafe(|| {
		let peer = match peer.as_ref() {
			Some(peer) => peer,
			None => return ERR,
		};
		let gate = peer.shared.open.lock().unwrap();
		open_result(&gate)
	}))
	.unwrap_or(ERR)
}

pub(crate) fn open_result(gate: &OpenGate) -> i32 {
	if gate.closed {
		return if gate.failed { ERR } else { CLOSED };
	}
	if gate.open {
		OK
	} else {
		WOULD_BLOCK
	}
}

/// Non-blocking receive for readiness owners. Returns one packet, zero at clean
/// EOF, `WOULD_BLOCK` when no packet is buffered yet, `BUFFER_TOO_SMALL` when
/// the packet remains queued for a larger buffer, or `ERR` on invalid input.
#[no_mangle]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_conn_try_receive_packet(
	peer: *mut GlowcapWebrtcPeer,
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
		if guard.packets.is_empty() {
			return terminal_read_result(&guard);
		}
		let dst = std::slice::from_raw_parts_mut(buf, len);
		let n = take_inbound_packet(&mut guard, dst);
		drop(guard);
		if n > 0 {
			peer.shared.drained.notify_one();
		}
		n
	}))
	.unwrap_or(ERR as isize)
}

/// Non-blocking send for readiness owners. The call copies one whole packet
/// into the bounded sidecar staging buffer and returns immediately, without
/// entering the async runtime. `WOULD_BLOCK` means no sidecar capacity is
/// available, so re-arm on `EV_WRITABLE` and retry the same packet.
#[no_mangle]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_conn_try_send_packet(
	peer: *mut GlowcapWebrtcPeer,
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

/// Close the channel, waking any packet receiver with end of stream.
/// Idempotent; `peer_free` still frees the handle afterward.
///
/// # Safety
/// `peer` must be a live pointer from `peer_new`.
#[no_mangle]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_conn_close(peer: *mut GlowcapWebrtcPeer) {
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
pub unsafe extern "C" fn glowcap_webrtc_sidecar_peer_free(peer: *mut GlowcapWebrtcPeer) {
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
