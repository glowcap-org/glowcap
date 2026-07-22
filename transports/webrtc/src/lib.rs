//! The WebRTC DataChannel netlayer sidecar (ADR-0089, phase 2).
//!
//! This staticlib wraps one `RTCPeerConnection` and its single reliable, ordered
//! `RTCDataChannel` behind a narrow blocking C ABI, emitting
//! `libpancake_webrtc_sidecar.a`. The Zig resident
//! (`src/net/transport/webrtc.zig`) is the only consumer. It mirrors the iroh
//! sidecar's shape (ADR-0055), with the differences WebRTC forces:
//!
//! * Each peer owns its own tokio runtime behind the opaque handle, so a caller
//!   needs no async runtime of its own; every C call blocks the calling thread
//!   by running `block_on` against that runtime. The runtime bill is two worker
//!   threads named `pancake-webrtc`, enough for the ICE, DTLS, and SCTP driver
//!   tasks while the caller's own threads do the blocking.
//! * A peer has no dialable address, so there is no `connect(addr)`. Instead the
//!   caller drives an out-of-band signaling exchange: the offerer produces an
//!   SDP offer, the answerer an SDP answer, and both trickle ICE candidates.
//!   Phase 2 carries these strings through a test harness; phase 5 (ADR-0089)
//!   routes them through an OCapN capability. The sidecar only produces and
//!   consumes the strings; it never transports them.
//! * The `RTCDataChannel` is callback-based (`on_message`), not a pollable
//!   stream, so inbound bytes are buffered behind a `Mutex`/`Condvar`. A
//!   blocking `conn_read` parks the caller's own thread on that condvar until
//!   bytes arrive or the channel closes, never touching the runtime.
//! * One channel, labelled `ocapn`, ordered and reliable, carries the whole
//!   OCapN session byte-for-byte. The offerer creates it; the answerer receives
//!   it through `on_data_channel`.
//! * No panic crosses the FFI boundary: every entry point runs under
//!   `catch_unwind` and maps a panic to the function's error return.
//!
//! The readiness-fd / non-blocking tier the iroh sidecar exposes for the
//! completion loop (ADR-0057) is not part of this phase: the blocking API below
//! carries the `BlockingSession` path the phase-2 `webrtc-interop` proof drives.

use std::collections::VecDeque;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use bytes::Bytes;
use tokio::runtime::Runtime;
use webrtc::api::interceptor_registry::register_default_interceptors;
use webrtc::api::media_engine::MediaEngine;
use webrtc::api::setting_engine::SettingEngine;
use webrtc::api::APIBuilder;
use webrtc::data_channel::data_channel_init::RTCDataChannelInit;
use webrtc::data_channel::data_channel_message::DataChannelMessage;
use webrtc::data_channel::RTCDataChannel;
use webrtc::ice_transport::ice_candidate::RTCIceCandidateInit;
use webrtc::interceptor::registry::Registry;
use webrtc::peer_connection::configuration::RTCConfiguration;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;
use webrtc::peer_connection::RTCPeerConnection;

/// The label of the one data channel a pancake `webrtc` session runs over. Both
/// peers agree on it out of band; the offerer creates it under this name.
const CHANNEL_LABEL: &str = "ocapn";

/// Return codes shared with the Zig resident and the header. `0` is success;
/// negatives name the failure family the resident maps to a Zig error.
const OK: i32 = 0;
const ERR: i32 = -1;
/// A drain call (`peer_next_local_candidate`) or a wait (`peer_wait_open`) that
/// cannot make progress yet: no candidate has gathered, or the channel is not
/// open. The resident re-arms and retries, distinct from a hard error.
const WOULD_BLOCK: i32 = -2;
/// A string out-parameter whose buffer was too small; `*out_len` is set to the
/// length the caller must provide, and nothing is written.
const BUFFER_TOO_SMALL: i32 = -3;

/// Inbound bytes buffered from the data channel's `on_message` callback, drained
/// by a blocking `conn_read`. `closed` latches when the channel closes or the
/// peer tears down, so a reader parked on the condvar wakes and returns clean
/// end of stream.
struct Inbound {
	buf: VecDeque<u8>,
	closed: bool,
}

/// A one-shot latch flipped when the data channel opens, so `peer_wait_open`
/// blocks the caller until the DTLS/SCTP bring-up completes.
struct OpenGate {
	open: bool,
}

/// One WebRTC peer: its runtime, peer connection, the single data channel once
/// it exists, and the shared buffers the async callbacks feed. Opaque to C.
pub struct PancakeWebrtcPeer {
	rt: Runtime,
	pc: Arc<RTCPeerConnection>,
	/// The data channel: created immediately for an offerer, installed by
	/// `on_data_channel` for an answerer. `conn_write` reads it; a write before
	/// the answerer's channel arrives returns `ERR`.
	dc: Arc<Mutex<Option<Arc<RTCDataChannel>>>>,
	inbound: Arc<(Mutex<Inbound>, Condvar)>,
	open: Arc<(Mutex<OpenGate>, Condvar)>,
	/// Locally gathered ICE candidates, serialized as JSON, awaiting the caller
	/// to drain and ferry to the far peer.
	local_candidates: Arc<Mutex<VecDeque<String>>>,
}

/// Build the data-channel-only WebRTC API, mirroring the phase-1 probe: default
/// codecs and interceptors, plus loopback ICE candidates so two peers on one
/// host connect with no STUN. Higher layers add STUN/TURN when a deployment
/// needs NAT traversal (ADR-0089); the sidecar itself stays relay-less.
fn build_peer_connection(rt: &Runtime) -> Result<Arc<RTCPeerConnection>, webrtc::Error> {
	let mut setting_engine = SettingEngine::default();
	setting_engine.set_include_loopback_candidate(true);

	let mut media_engine = MediaEngine::default();
	media_engine.register_default_codecs()?;
	let mut registry = Registry::new();
	registry = register_default_interceptors(registry, &mut media_engine)?;

	let api = APIBuilder::new()
		.with_media_engine(media_engine)
		.with_interceptor_registry(registry)
		.with_setting_engine(setting_engine)
		.build();

	let config = RTCConfiguration::default();
	let pc = rt.block_on(api.new_peer_connection(config))?;
	Ok(Arc::new(pc))
}

/// Wire a data channel's `on_open` and `on_message` handlers to this peer's
/// shared latches, so a blocking `conn_read` and `peer_wait_open` see its
/// events. Used for both the offerer's created channel and the answerer's
/// received one.
fn wire_channel(
	dc: &Arc<RTCDataChannel>,
	inbound: Arc<(Mutex<Inbound>, Condvar)>,
	open: Arc<(Mutex<OpenGate>, Condvar)>,
) {
	let open_for_cb = open.clone();
	dc.on_open(Box::new(move || {
		let open = open_for_cb.clone();
		Box::pin(async move {
			let (lock, cvar) = &*open;
			lock.lock().unwrap().open = true;
			cvar.notify_all();
		})
	}));

	let inbound_for_msg = inbound.clone();
	dc.on_message(Box::new(move |msg: DataChannelMessage| {
		let inbound = inbound_for_msg.clone();
		Box::pin(async move {
			let (lock, cvar) = &*inbound;
			lock.lock().unwrap().buf.extend(msg.data.iter().copied());
			cvar.notify_all();
		})
	}));

	// The far peer closing its channel unblocks a parked reader with end of
	// stream, the same as a local `conn_close`.
	let inbound_for_close = inbound;
	dc.on_close(Box::new(move || {
		let inbound = inbound_for_close.clone();
		Box::pin(async move {
			mark_closed(&inbound);
		})
	}));
}

/// Latch the inbound buffer closed and wake any parked reader. Called on channel
/// close and on peer teardown.
fn mark_closed(inbound: &Arc<(Mutex<Inbound>, Condvar)>) {
	let (lock, cvar) = &**inbound;
	lock.lock().unwrap().closed = true;
	cvar.notify_all();
}

/// Create a peer. `is_offerer` chooses the role: an offerer creates the `ocapn`
/// data channel now; an answerer installs it when `on_data_channel` fires.
/// Returns a heap `PancakeWebrtcPeer` the caller frees with `peer_free`, or null
/// on failure.
///
/// # Safety
/// The returned pointer is owned by the caller and must be freed exactly once
/// with `pancake_webrtc_sidecar_peer_free`.
#[no_mangle]
pub extern "C" fn pancake_webrtc_sidecar_peer_new(is_offerer: i32) -> *mut PancakeWebrtcPeer {
	catch_unwind(AssertUnwindSafe(|| {
		let rt = match tokio::runtime::Builder::new_multi_thread()
			.worker_threads(2)
			.thread_name("pancake-webrtc")
			.enable_all()
			.build()
		{
			Ok(rt) => rt,
			Err(_) => return std::ptr::null_mut(),
		};

		let pc = match build_peer_connection(&rt) {
			Ok(pc) => pc,
			Err(_) => return std::ptr::null_mut(),
		};

		let inbound = Arc::new((
			Mutex::new(Inbound {
				buf: VecDeque::new(),
				closed: false,
			}),
			Condvar::new(),
		));
		let open = Arc::new((Mutex::new(OpenGate { open: false }), Condvar::new()));
		let local_candidates: Arc<Mutex<VecDeque<String>>> = Arc::new(Mutex::new(VecDeque::new()));
		let dc_slot: Arc<Mutex<Option<Arc<RTCDataChannel>>>> = Arc::new(Mutex::new(None));

		// Trickle locally gathered ICE candidates into the drain queue as JSON.
		let cand_queue = local_candidates.clone();
		pc.on_ice_candidate(Box::new(move |candidate| {
			let cand_queue = cand_queue.clone();
			Box::pin(async move {
				if let Some(candidate) = candidate {
					if let Ok(init) = candidate.to_json() {
						if let Ok(text) = serde_json::to_string(&init) {
							cand_queue.lock().unwrap().push_back(text);
						}
					}
				}
			})
		}));

		if is_offerer != 0 {
			let init = RTCDataChannelInit {
				ordered: Some(true),
				..Default::default()
			};
			let dc = match rt.block_on(pc.create_data_channel(CHANNEL_LABEL, Some(init))) {
				Ok(dc) => dc,
				Err(_) => return std::ptr::null_mut(),
			};
			wire_channel(&dc, inbound.clone(), open.clone());
			*dc_slot.lock().unwrap() = Some(dc);
		} else {
			let inbound_for_dc = inbound.clone();
			let open_for_dc = open.clone();
			let slot_for_dc = dc_slot.clone();
			pc.on_data_channel(Box::new(move |dc: Arc<RTCDataChannel>| {
				let inbound = inbound_for_dc.clone();
				let open = open_for_dc.clone();
				let slot = slot_for_dc.clone();
				Box::pin(async move {
					wire_channel(&dc, inbound, open);
					*slot.lock().unwrap() = Some(dc);
				})
			}));
		}

		let peer = Box::new(PancakeWebrtcPeer {
			rt,
			pc,
			dc: dc_slot,
			inbound,
			open,
			local_candidates,
		});
		Box::into_raw(peer)
	}))
	.unwrap_or(std::ptr::null_mut())
}

/// Copy `text` into the `(out, cap)` buffer, always writing the required length
/// to `*out_len`. Returns `OK` when it fit, `BUFFER_TOO_SMALL` when the caller
/// must retry with a larger buffer.
///
/// # Safety
/// `out` must point to `cap` writable bytes; `out_len` must be a valid pointer.
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

/// Produce this peer's SDP offer: `create_offer` then `set_local_description`,
/// writing the offer SDP into `(out, cap)`. Offerer only.
///
/// # Safety
/// `peer` must be a live pointer from `peer_new`; `out`/`out_len` per `write_out`.
#[no_mangle]
pub unsafe extern "C" fn pancake_webrtc_sidecar_peer_create_offer(
	peer: *mut PancakeWebrtcPeer,
	out: *mut u8,
	cap: usize,
	out_len: *mut usize,
) -> i32 {
	catch_unwind(AssertUnwindSafe(|| {
		let peer = match peer.as_ref() {
			Some(peer) => peer,
			None => return ERR,
		};
		let offer = match peer.rt.block_on(peer.pc.create_offer(None)) {
			Ok(offer) => offer,
			Err(_) => return ERR,
		};
		if peer
			.rt
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
pub unsafe extern "C" fn pancake_webrtc_sidecar_peer_create_answer(
	peer: *mut PancakeWebrtcPeer,
	out: *mut u8,
	cap: usize,
	out_len: *mut usize,
) -> i32 {
	catch_unwind(AssertUnwindSafe(|| {
		let peer = match peer.as_ref() {
			Some(peer) => peer,
			None => return ERR,
		};
		let answer = match peer.rt.block_on(peer.pc.create_answer(None)) {
			Ok(answer) => answer,
			Err(_) => return ERR,
		};
		if peer
			.rt
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
/// `peer` live; `sdp` points to `sdp_len` readable bytes of UTF-8.
#[no_mangle]
pub unsafe extern "C" fn pancake_webrtc_sidecar_peer_set_remote(
	peer: *mut PancakeWebrtcPeer,
	sdp: *const u8,
	sdp_len: usize,
	is_offer: i32,
) -> i32 {
	catch_unwind(AssertUnwindSafe(|| {
		let peer = match peer.as_ref() {
			Some(peer) => peer,
			None => return ERR,
		};
		if sdp.is_null() {
			return ERR;
		}
		let bytes = std::slice::from_raw_parts(sdp, sdp_len);
		let text = match std::str::from_utf8(bytes) {
			Ok(text) => text.to_string(),
			Err(_) => return ERR,
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
			.rt
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
/// `peer` live; `cand` points to `cand_len` readable bytes of UTF-8 JSON.
#[no_mangle]
pub unsafe extern "C" fn pancake_webrtc_sidecar_peer_add_remote_candidate(
	peer: *mut PancakeWebrtcPeer,
	cand: *const u8,
	cand_len: usize,
) -> i32 {
	catch_unwind(AssertUnwindSafe(|| {
		let peer = match peer.as_ref() {
			Some(peer) => peer,
			None => return ERR,
		};
		if cand.is_null() {
			return ERR;
		}
		let bytes = std::slice::from_raw_parts(cand, cand_len);
		let text = match std::str::from_utf8(bytes) {
			Ok(text) => text,
			Err(_) => return ERR,
		};
		let init: RTCIceCandidateInit = match serde_json::from_str(text) {
			Ok(init) => init,
			Err(_) => return ERR,
		};
		if peer.rt.block_on(peer.pc.add_ice_candidate(init)).is_err() {
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
pub unsafe extern "C" fn pancake_webrtc_sidecar_peer_next_local_candidate(
	peer: *mut PancakeWebrtcPeer,
	out: *mut u8,
	cap: usize,
	out_len: *mut usize,
) -> i32 {
	catch_unwind(AssertUnwindSafe(|| {
		let peer = match peer.as_ref() {
			Some(peer) => peer,
			None => return ERR,
		};
		let mut queue = peer.local_candidates.lock().unwrap();
		let text = match queue.front() {
			Some(text) => text.clone(),
			None => return WOULD_BLOCK,
		};
		let rc = write_out(&text, out, cap, out_len);
		if rc == OK {
			queue.pop_front();
		}
		rc
	}))
	.unwrap_or(ERR)
}

/// Block until the data channel opens, or `timeout_ms` elapses. Returns `OK`
/// once open, `WOULD_BLOCK` on timeout.
///
/// # Safety
/// `peer` must be a live pointer from `peer_new`.
#[no_mangle]
pub unsafe extern "C" fn pancake_webrtc_sidecar_peer_wait_open(
	peer: *mut PancakeWebrtcPeer,
	timeout_ms: u64,
) -> i32 {
	catch_unwind(AssertUnwindSafe(|| {
		let peer = match peer.as_ref() {
			Some(peer) => peer,
			None => return ERR,
		};
		let (lock, cvar) = &*peer.open;
		let mut guard = lock.lock().unwrap();
		if guard.open {
			return OK;
		}
		let (g, timed_out) = cvar
			.wait_timeout_while(guard, Duration::from_millis(timeout_ms), |g| !g.open)
			.unwrap();
		guard = g;
		if timed_out.timed_out() && !guard.open {
			WOULD_BLOCK
		} else {
			OK
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
		let (lock, cvar) = &*peer.inbound;
		let mut guard = lock.lock().unwrap();
		while guard.buf.is_empty() && !guard.closed {
			guard = cvar.wait(guard).unwrap();
		}
		if guard.buf.is_empty() {
			return 0; // closed, drained
		}
		// The one inherent copy of the callback-to-blocking bridge: `on_message`
		// buffered these bytes into the deque, and a blocking read has to hand a
		// contiguous slice back to its caller. Copy the deque's (up to two)
		// contiguous runs in bulk, then drop the drained prefix, rather than
		// popping a byte at a time.
		let n = guard.buf.len().min(len);
		let dst = std::slice::from_raw_parts_mut(buf, n);
		let (front, back) = guard.buf.as_slices();
		let from_front = front.len().min(n);
		dst[..from_front].copy_from_slice(&front[..from_front]);
		if from_front < n {
			dst[from_front..n].copy_from_slice(&back[..n - from_front]);
		}
		guard.buf.drain(..n);
		n as isize
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
		let dc = match peer.dc.lock().unwrap().clone() {
			Some(dc) => dc,
			None => return ERR as isize,
		};
		let bytes = Bytes::copy_from_slice(std::slice::from_raw_parts(buf, len));
		match peer.rt.block_on(dc.send(&bytes)) {
			Ok(_) => len as isize,
			Err(_) => ERR as isize,
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
	let _ = catch_unwind(AssertUnwindSafe(|| {
		if let Some(peer) = peer.as_ref() {
			let _ = peer.rt.block_on(peer.pc.close());
			mark_closed(&peer.inbound);
		}
	}));
}

/// Free a peer created by `peer_new`, dropping its runtime and connection.
///
/// # Safety
/// `peer` must have come from `peer_new` and not been freed; null is ignored.
#[no_mangle]
pub unsafe extern "C" fn pancake_webrtc_sidecar_peer_free(peer: *mut PancakeWebrtcPeer) {
	if peer.is_null() {
		return;
	}
	let _ = catch_unwind(AssertUnwindSafe(|| {
		let peer = Box::from_raw(peer);
		let _ = peer.rt.block_on(peer.pc.close());
		mark_closed(&peer.inbound);
		// `peer` drops here: the runtime shuts down as the Box frees.
	}));
}
