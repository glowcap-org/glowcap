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
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_peer_new(
	endpoint: *mut GlowcapWebrtcEndpoint,
	is_offerer: i32,
) -> *mut GlowcapWebrtcPeer {
	catch_unwind(AssertUnwindSafe(|| {
		// SAFETY: `endpoint` is a live handle from `endpoint_new`.
		let endpoint = match unsafe { endpoint.as_ref() } {
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

/// A caller's string out-parameter: `cap` bytes at `out`, plus the optional
/// `out_len` word that always receives the length the text needs, so a refused
/// write tells the caller what buffer to come back with.
///
/// Building one is the unsafe act, and it happens once per entry point. After
/// that the buffer's bounds are this value's own, so writing through it is
/// ordinary safe code — which is the difference between stating the caller's
/// contract once and restating it at every write.
pub(crate) struct OutText {
	out: *mut u8,
	cap: usize,
	out_len: *mut usize,
}

impl OutText {
	/// # Safety
	/// `out` is null or points to `cap` writable bytes, and `out_len` is null or
	/// points to one writable `usize`. Both stay valid while this value lives.
	pub(crate) unsafe fn new(out: *mut u8, cap: usize, out_len: *mut usize) -> Self {
		Self { out, cap, out_len }
	}

	fn report_len(&self, len: usize) {
		if !self.out_len.is_null() {
			// SAFETY: `new`'s contract — a non-null `out_len` is one writable word.
			unsafe { *self.out_len = len };
		}
	}

	/// Copy `text` in. `OK` when it fit, `BUFFER_TOO_SMALL` when the caller must
	/// retry with the length now reported.
	pub(crate) fn write(&self, text: &str) -> i32 {
		let bytes = text.as_bytes();
		self.report_len(bytes.len());
		if bytes.len() > self.cap || self.out.is_null() {
			return BUFFER_TOO_SMALL;
		}
		// SAFETY: `new`'s contract gives `cap` writable bytes at `out`, and the
		// arm above refused both a null `out` and a text longer than `cap`.
		unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), self.out, bytes.len()) };
		OK
	}

	/// True when `text` is past the hard signaling cap, so no caller buffer can
	/// make the call succeed. Reports the length anyway, for the diagnostic.
	pub(crate) fn too_large_to_signal(&self, text: &str) -> bool {
		if signal_output_fits(text) {
			return false;
		}
		self.report_len(text.len());
		true
	}
}

pub(crate) fn signal_output_fits(text: &str) -> bool {
	text.len() <= MAX_SIGNAL_BYTES
}

pub(crate) unsafe fn signal_text<'a>(ptr: *const u8, len: usize) -> Option<&'a str> {
	if ptr.is_null() || len > MAX_SIGNAL_BYTES {
		return None;
	}
	// SAFETY: the caller lends `len` readable bytes at `ptr` for this call, and
	// the null and oversized cases returned above.
	std::str::from_utf8(unsafe { std::slice::from_raw_parts(ptr, len) }).ok()
}

pub(crate) unsafe fn candidate_text<'a>(ptr: *const u8, len: usize) -> Option<&'a str> {
	if ptr.is_null() || len > MAX_ICE_CANDIDATE_BYTES {
		return None;
	}
	// SAFETY: as `signal_text`, under the candidate bound.
	std::str::from_utf8(unsafe { std::slice::from_raw_parts(ptr, len) }).ok()
}

pub(crate) fn write_local_candidate(queue: &mut LocalCandidates, out: &OutText) -> i32 {
	let text = match queue.items.front() {
		Some(text) => text.as_str(),
		None => return WOULD_BLOCK,
	};
	let rc = out.write(text);
	if rc == OK {
		queue.release_front();
	}
	rc
}

/// Produce this peer's SDP offer: `create_offer` then `set_local_description`,
/// writing the offer SDP into `(out, cap)`. Offerer only.
///
/// # Safety
/// `peer` per `borrowed`; `out`/`out_len` per `OutText::new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_peer_create_offer(
	peer: *mut GlowcapWebrtcPeer,
	out: *mut u8,
	cap: usize,
	out_len: *mut usize,
) -> i32 {
	// SAFETY: the out-parameter contract this function's own doc states.
	let out = unsafe { OutText::new(out, cap, out_len) };
	let offer = |peer: &GlowcapWebrtcPeer| {
		let offer = match peer.shared.endpoint.runtime().block_on(peer.pc.create_offer(None)) {
			Ok(offer) => offer,
			Err(_) => return ERR,
		};
		if out.too_large_to_signal(&offer.sdp) {
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
		out.write(&offer.sdp)
	};
	// SAFETY: the handle contract `borrowed` states.
	unsafe { borrowed(peer, ERR, offer) }
}

/// Produce this peer's SDP answer: `create_answer` then `set_local_description`,
/// writing the answer SDP into `(out, cap)`. Answerer only, after the remote
/// offer is set.
///
/// # Safety
/// `peer` per `borrowed`; `out`/`out_len` per `OutText::new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_peer_create_answer(
	peer: *mut GlowcapWebrtcPeer,
	out: *mut u8,
	cap: usize,
	out_len: *mut usize,
) -> i32 {
	// SAFETY: the out-parameter contract this function's own doc states.
	let out = unsafe { OutText::new(out, cap, out_len) };
	let answer = |peer: &GlowcapWebrtcPeer| {
		let answer = match peer.shared.endpoint.runtime().block_on(peer.pc.create_answer(None)) {
			Ok(answer) => answer,
			Err(_) => return ERR,
		};
		if out.too_large_to_signal(&answer.sdp) {
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
		out.write(&answer.sdp)
	};
	// SAFETY: the handle contract `borrowed` states.
	unsafe { borrowed(peer, ERR, answer) }
}

/// Set the remote peer's SDP. `is_offer` picks the description type: nonzero for
/// the offerer's offer (set by the answerer), zero for the answerer's answer
/// (set by the offerer).
///
/// # Safety
/// `peer` live; `sdp` points to `sdp_len` readable bytes of UTF-8, with
/// `sdp_len <= MAX_SIGNAL_BYTES`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_peer_set_remote(
	peer: *mut GlowcapWebrtcPeer,
	sdp: *const u8,
	sdp_len: usize,
	is_offer: i32,
) -> i32 {
	// SAFETY: the `sdp` view is live for this call per the contract above.
	let text = match unsafe { signal_text(sdp, sdp_len) } {
		Some(text) => text.to_string(),
		None => return ERR,
	};
	let set_remote = |peer: &GlowcapWebrtcPeer| {
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
	};
	// SAFETY: the handle contract `borrowed` states.
	unsafe { borrowed(peer, ERR, set_remote) }
}

/// Add one remote ICE candidate, as the JSON the far peer's
/// `peer_next_local_candidate` produced.
///
/// # Safety
/// `peer` live; `cand` points to `cand_len` readable bytes of UTF-8 JSON, with
/// `cand_len <= MAX_ICE_CANDIDATE_BYTES`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_peer_add_remote_candidate(
	peer: *mut GlowcapWebrtcPeer,
	cand: *const u8,
	cand_len: usize,
) -> i32 {
	// SAFETY: the `cand` view is live for this call per the contract above.
	let text = match unsafe { candidate_text(cand, cand_len) } {
		Some(text) => text,
		None => return ERR,
	};
	let add_candidate = |peer: &GlowcapWebrtcPeer| {
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
	};
	// SAFETY: the handle contract `borrowed` states.
	unsafe { borrowed(peer, ERR, add_candidate) }
}

/// Drain the next locally gathered ICE candidate into `(out, cap)` as JSON.
/// Returns `OK` with one candidate, `WOULD_BLOCK` when none is pending, or
/// `BUFFER_TOO_SMALL` (the candidate stays queued for the retry).
///
/// # Safety
/// `peer` per `borrowed`; `out`/`out_len` per `OutText::new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_peer_next_local_candidate(
	peer: *mut GlowcapWebrtcPeer,
	out: *mut u8,
	cap: usize,
	out_len: *mut usize,
) -> i32 {
	// SAFETY: the out-parameter contract this function's own doc states.
	let out = unsafe { OutText::new(out, cap, out_len) };
	let next =
		|peer: &GlowcapWebrtcPeer| write_local_candidate(&mut peer.shared.local_candidates.lock().unwrap(), &out);
	// SAFETY: the handle contract `borrowed` states.
	unsafe { borrowed(peer, ERR, next) }
}
