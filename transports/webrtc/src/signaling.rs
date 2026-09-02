//! Peer admission and the signaling exchange: peer creation, offer and
//! answer minting, remote descriptions, and ICE candidates in both
//! directions.

use super::*;

pub(crate) fn mint_peer_id(endpoint: &EndpointInner) -> Option<usize> {
	endpoint
		.next_peer_id
		.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |id| id.checked_add(1))
		.ok()
		.filter(|id| *id != 0)
}

/// Create a peer. `is_offerer` chooses the role: an offerer creates the `ocapn`
/// data channel now; an answerer installs it when `on_data_channel` fires.
/// Returns a heap `GlowcapWebrtcPeer` the caller frees with `peer_free`, or null
/// on failure.
///
/// # Safety
/// The returned pointer is owned by the caller and must be freed exactly once
/// with `glowcap_webrtc_sidecar_peer_free`.
#[no_mangle]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_peer_new(
	endpoint: *mut GlowcapWebrtcEndpoint,
	is_offerer: i32,
) -> *mut GlowcapWebrtcPeer {
	catch_unwind(AssertUnwindSafe(|| {
		let endpoint = match endpoint.as_ref() {
			Some(endpoint) => endpoint.inner.clone(),
			None => return std::ptr::null_mut(),
		};
		let id = match mint_peer_id(&endpoint) {
			Some(id) => id,
			None => return std::ptr::null_mut(),
		};
		let shared = Arc::new(PeerShared {
			endpoint: endpoint.clone(),
			id,
			close_started: AtomicBool::new(false),
			pc: Mutex::new(None),
			dc: Mutex::new(None),
			inbound: Arc::new((
				Mutex::new(Inbound {
					packets: VecDeque::new(),
					queued_bytes: 0,
					closed: false,
					failed: false,
				}),
				Condvar::new(),
			)),
			drained: Arc::new(Notify::new()),
			outbound: Arc::new(Mutex::new(Outbound {
				packets: VecDeque::new(),
				queued_bytes: 0,
				closed: false,
			})),
			outbound_ready: Arc::new(Notify::new()),
			open: Arc::new(Mutex::new(OpenGate {
				open: false,
				closed: false,
				failed: false,
			})),
			local_candidates: Arc::new(Mutex::new(LocalCandidates::new())),
		});
		let handler = Arc::new(PeerEvents {
			shared: shared.clone(),
			runtime: endpoint.runtime().handle().clone(),
		});
		let pc = match peer_connection::build(
			endpoint.runtime(),
			handler,
			&endpoint.ice_servers,
			endpoint.include_loopback,
			SCTP_RECEIVE_BUFFER_BOUND,
			OUTBOUND_BUFFER_BOUND,
		) {
			Ok(pc) => pc,
			Err(_) => return std::ptr::null_mut(),
		};
		*shared.pc.lock().unwrap() = Some(Arc::downgrade(&pc));
		if shared.open.lock().unwrap().closed {
			close_shared_async(&shared);
		}

		if is_offerer != 0 {
			let init = RTCDataChannelInit {
				ordered: true,
				..Default::default()
			};
			let dc = match endpoint
				.runtime()
				.block_on(pc.create_data_channel(CHANNEL_LABEL, Some(init)))
			{
				Ok(dc) => dc,
				Err(_) => return std::ptr::null_mut(),
			};
			*shared.dc.lock().unwrap() = Some(dc.clone());
			wire_channel(dc, shared.clone());
		}

		let peer = Box::new(GlowcapWebrtcPeer { shared, pc });
		Box::into_raw(peer)
	}))
	.unwrap_or(std::ptr::null_mut())
}

/// Copy `text` into the `(out, cap)` buffer, always writing the required length
/// to `*out_len`. Returns `OK` when it fit, `BUFFER_TOO_SMALL` when the caller
/// must retry with a larger buffer.
///
/// # Safety
/// `out` must point to `cap` writable bytes. `out_len` may be null; when
/// non-null it receives the required byte count.
unsafe fn write_out(text: &str, out: *mut u8, cap: usize, out_len: *mut usize) -> i32 {
	let bytes = text.as_bytes();
	if !out_len.is_null() {
		*out_len = bytes.len();
	}
	if bytes.len() > cap || out.is_null() {
		return BUFFER_TOO_SMALL;
	}
	std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, bytes.len());
	OK
}

pub(crate) fn signal_output_fits(text: &str) -> bool {
	text.len() <= MAX_SIGNAL_BYTES
}

pub(crate) unsafe fn signal_output_too_large(text: &str, out_len: *mut usize) -> bool {
	if signal_output_fits(text) {
		return false;
	}
	if !out_len.is_null() {
		*out_len = text.len();
	}
	true
}

pub(crate) unsafe fn signal_text<'a>(ptr: *const u8, len: usize) -> Option<&'a str> {
	if ptr.is_null() || len > MAX_SIGNAL_BYTES {
		return None;
	}
	std::str::from_utf8(std::slice::from_raw_parts(ptr, len)).ok()
}

pub(crate) unsafe fn candidate_text<'a>(ptr: *const u8, len: usize) -> Option<&'a str> {
	if ptr.is_null() || len > MAX_ICE_CANDIDATE_BYTES {
		return None;
	}
	std::str::from_utf8(std::slice::from_raw_parts(ptr, len)).ok()
}

pub(crate) unsafe fn write_local_candidate(
	queue: &mut LocalCandidates,
	out: *mut u8,
	cap: usize,
	out_len: *mut usize,
) -> i32 {
	let text = match queue.items.front() {
		Some(text) => text.as_str(),
		None => return WOULD_BLOCK,
	};
	let rc = write_out(text, out, cap, out_len);
	if rc == OK {
		queue.release_front();
	}
	rc
}

/// Produce this peer's SDP offer: `create_offer` then `set_local_description`,
/// writing the offer SDP into `(out, cap)`. Offerer only.
///
/// # Safety
/// `peer` must be a live pointer from `peer_new`; `out`/`out_len` per `write_out`.
#[no_mangle]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_peer_create_offer(
	peer: *mut GlowcapWebrtcPeer,
	out: *mut u8,
	cap: usize,
	out_len: *mut usize,
) -> i32 {
	catch_unwind(AssertUnwindSafe(|| {
		let peer = match peer.as_ref() {
			Some(peer) => peer,
			None => return ERR,
		};
		let offer = match peer.shared.endpoint.runtime().block_on(peer.pc.create_offer(None)) {
			Ok(offer) => offer,
			Err(_) => return ERR,
		};
		if signal_output_too_large(&offer.sdp, out_len) {
			return SIGNAL_TOO_LARGE;
		}
		if peer
			.shared
			.endpoint
			.runtime()
			.block_on(peer.pc.set_local_description(offer.clone()))
			.is_err()
		{
			return ERR;
		}
		write_out(&offer.sdp, out, cap, out_len)
	}))
	.unwrap_or(ERR)
}

/// Produce this peer's SDP answer: `create_answer` then `set_local_description`,
/// writing the answer SDP into `(out, cap)`. Answerer only, after the remote
/// offer is set.
///
/// # Safety
/// `peer` must be a live pointer from `peer_new`; `out`/`out_len` per `write_out`.
#[no_mangle]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_peer_create_answer(
	peer: *mut GlowcapWebrtcPeer,
	out: *mut u8,
	cap: usize,
	out_len: *mut usize,
) -> i32 {
	catch_unwind(AssertUnwindSafe(|| {
		let peer = match peer.as_ref() {
			Some(peer) => peer,
			None => return ERR,
		};
		let answer = match peer.shared.endpoint.runtime().block_on(peer.pc.create_answer(None)) {
			Ok(answer) => answer,
			Err(_) => return ERR,
		};
		if signal_output_too_large(&answer.sdp, out_len) {
			return SIGNAL_TOO_LARGE;
		}
		if peer
			.shared
			.endpoint
			.runtime()
			.block_on(peer.pc.set_local_description(answer.clone()))
			.is_err()
		{
			return ERR;
		}
		write_out(&answer.sdp, out, cap, out_len)
	}))
	.unwrap_or(ERR)
}

/// Set the remote peer's SDP. `is_offer` picks the description type: nonzero for
/// the offerer's offer (set by the answerer), zero for the answerer's answer
/// (set by the offerer).
///
/// # Safety
/// `peer` live; `sdp` points to `sdp_len` readable bytes of UTF-8, with
/// `sdp_len <= MAX_SIGNAL_BYTES`.
#[no_mangle]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_peer_set_remote(
	peer: *mut GlowcapWebrtcPeer,
	sdp: *const u8,
	sdp_len: usize,
	is_offer: i32,
) -> i32 {
	catch_unwind(AssertUnwindSafe(|| {
		let peer = match peer.as_ref() {
			Some(peer) => peer,
			None => return ERR,
		};
		let text = match signal_text(sdp, sdp_len) {
			Some(text) => text.to_string(),
			None => return ERR,
		};
		let desc = if is_offer != 0 {
			RTCSessionDescription::offer(text)
		} else {
			RTCSessionDescription::answer(text)
		};
		let desc = match desc {
			Ok(desc) => desc,
			Err(_) => return ERR,
		};
		if peer
			.shared
			.endpoint
			.runtime()
			.block_on(peer.pc.set_remote_description(desc))
			.is_err()
		{
			return ERR;
		}
		OK
	}))
	.unwrap_or(ERR)
}

/// Add one remote ICE candidate, as the JSON the far peer's
/// `peer_next_local_candidate` produced.
///
/// # Safety
/// `peer` live; `cand` points to `cand_len` readable bytes of UTF-8 JSON, with
/// `cand_len <= MAX_ICE_CANDIDATE_BYTES`.
#[no_mangle]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_peer_add_remote_candidate(
	peer: *mut GlowcapWebrtcPeer,
	cand: *const u8,
	cand_len: usize,
) -> i32 {
	catch_unwind(AssertUnwindSafe(|| {
		let peer = match peer.as_ref() {
			Some(peer) => peer,
			None => return ERR,
		};
		let text = match candidate_text(cand, cand_len) {
			Some(text) => text,
			None => return ERR,
		};
		let init: RTCIceCandidateInit = match serde_json::from_str(text) {
			Ok(init) => init,
			Err(_) => return ERR,
		};
		if peer
			.shared
			.endpoint
			.runtime()
			.block_on(peer.pc.add_ice_candidate(init))
			.is_err()
		{
			return ERR;
		}
		OK
	}))
	.unwrap_or(ERR)
}

/// Drain the next locally gathered ICE candidate into `(out, cap)` as JSON.
/// Returns `OK` with one candidate, `WOULD_BLOCK` when none is pending, or
/// `BUFFER_TOO_SMALL` (the candidate stays queued for the retry).
///
/// # Safety
/// `peer` live; `out`/`out_len` per `write_out`.
#[no_mangle]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_peer_next_local_candidate(
	peer: *mut GlowcapWebrtcPeer,
	out: *mut u8,
	cap: usize,
	out_len: *mut usize,
) -> i32 {
	catch_unwind(AssertUnwindSafe(|| {
		let peer = match peer.as_ref() {
			Some(peer) => peer,
			None => return ERR,
		};
		write_local_candidate(&mut peer.shared.local_candidates.lock().unwrap(), out, cap, out_len)
	}))
	.unwrap_or(ERR)
}
