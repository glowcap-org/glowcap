//! The native WebRTC DataChannel sidecar (ADR-0089).
//!
//! This staticlib wraps WebRTC peers and their reliable, ordered
//! `RTCDataChannel`s behind a narrow C ABI, emitting
//! `libpancake_webrtc_sidecar.a`. The Zig resident
//! (`src/net/transport/webrtc.zig`) is the only consumer. It mirrors the iroh
//! sidecar's shape (ADR-0055), with the differences WebRTC forces:
//!
//! * One endpoint owns the tokio runtime and readiness fd shared by every peer
//!   created from it. Async channel state is reported as endpoint readiness
//!   records carrying stable peer ids; readiness drains and try-I/O never park
//!   the caller's reactor thread.
//! * A peer has no dialable address, so there is no `connect(addr)`. Instead the
//!   caller drives an out-of-band signaling exchange: the offerer produces an
//!   SDP offer, the answerer an SDP answer, and both trickle ICE candidates.
//!   The caller may carry these strings out of band or through an OCapN signaling
//!   capability. The sidecar only produces and consumes them; it never transports
//!   them. Peer creation and signaling submissions are synchronous control-plane
//!   calls; the readiness path begins once those inputs are submitted.
//! * The `RTCDataChannel` is pollable and exposes send-side backpressure.
//!   C-facing try-writes admit into a bounded sidecar staging buffer, then an
//!   async drain task sends through `DataChannel::send` without parking the
//!   caller's reactor thread. The private blocking byte calls remain only for
//!   the Zig `BlockingSession` connection; public evented consumers use
//!   readiness.
//! * One channel, labelled `ocapn`, ordered and reliable, carries the whole
//!   OCapN session byte-for-byte. The offerer creates it; the answerer receives
//!   it through `on_data_channel`.
//! * No panic crosses the FFI boundary: every entry point runs under
//!   `catch_unwind` and maps a panic to the function's error return.
//!
mod channel;
mod conn;
mod lifecycle;
mod peer_connection;
mod signaling;

use channel::*;
mod readiness;

use std::collections::VecDeque;
use std::os::fd::AsRawFd;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};

use bytes::BytesMut;
use tokio::runtime::Handle;
use tokio::sync::Notify;
use webrtc::data_channel::{DataChannel, DataChannelEvent, RTCDataChannelInit};
use webrtc::error::Error as WebrtcError;
use webrtc::peer_connection::{
	PeerConnection, PeerConnectionEventHandler, RTCIceCandidateInit, RTCPeerConnectionIceEvent, RTCPeerConnectionState,
	RTCSessionDescription,
};

use lifecycle::{CloseTasks, RuntimeOwner};
use readiness::Readiness;

/// The label of the one data channel a pancake `webrtc` session runs over. Both
/// peers agree on it out of band; the offerer creates it under this name.
const CHANNEL_LABEL: &str = "ocapn";

/// Worker threads for one endpoint's runtime when the caller names none. Two is
/// enough for the callback and send work of a handful of channels, and it is a
/// per-endpoint cost, so a process holding many endpoints, or one endpoint
/// holding many peers, should say what it wants instead.
const WORKER_THREADS: usize = 2;

/// Maximum time the crate may retain one peer after pancake has committed its
/// local close. WebRTC close is control-plane teardown, not application grace;
/// it must not make the endpoint's final release barrier unbounded. Fifteen
/// seconds matches the transport-level dead-peer bound used by the iroh
/// sidecar and is ample for SCTP/DTLS shutdown without licensing a stuck task.
const PEER_CLOSE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);

/// Return codes shared with the Zig resident and the header. `0` is success;
/// negatives name the failure family the resident maps to a Zig error.
const OK: i32 = 0;
const ERR: i32 = -1;

fn teardown_status(f: impl FnOnce() -> Result<(), ()>) -> i32 {
	match catch_unwind(AssertUnwindSafe(f)) {
		Ok(Ok(())) => OK,
		Ok(Err(())) | Err(_) => ERR,
	}
}
/// A non-blocking call that cannot make progress yet: no candidate has gathered,
/// the channel is not open, or a bounded queue has no room. The resident re-arms
/// and retries, distinct from a hard error.
const WOULD_BLOCK: i32 = -2;
/// A string out-parameter whose buffer was too small; `*out_len` is set to the
/// length the caller must provide, and nothing is written.
const BUFFER_TOO_SMALL: i32 = -3;

/// Readiness bits shared with the Zig resident and public C ABI. One drained
/// record may carry several bits for the same stable endpoint-scoped peer id.
const EV_OPEN: u32 = 1;
const EV_CANDIDATE: u32 = 2;
const EV_READABLE: u32 = 4;
const EV_WRITABLE: u32 = 8;
const EV_CLOSED: u32 = 16;

/// One endpoint's configuration, passed by pointer so a new setting is a field
/// rather than a wider signature every caller has to agree on. What the setting
/// means is documented once, on the C ABI's `PancakeWebrtcConfig`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct PancakeWebrtcEndpointConfig {
	/// Comma-separated ICE server URLs, borrowed for the call. Null or empty is
	/// host candidates only.
	pub ice_servers: *const u8,
	pub ice_servers_len: usize,
	/// Nonzero offers loopback ICE candidates, which is what lets two peers in
	/// one process or on one host connect with no STUN.
	pub include_loopback_candidates: u32,
	/// Worker threads for this endpoint's runtime; 0 takes the default.
	pub worker_threads: u32,
}

/// One endpoint readiness record. `subject` is a stable peer id minted by the
/// endpoint and never reused during its lifetime.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct PancakeWebrtcReadyEvent {
	pub subject: usize,
	pub events: u32,
}

/// How many unread inbound bytes may pile up in the C-facing staging buffer
/// before the sidecar pauses its channel poller.
const INBOUND_BUFFER_BOUND: usize = 1 << 20;

/// The SCTP receive window bound passed to `webrtc` 0.20. It is separate from
/// the C-facing staging bound above: the crate may hold bytes it has received
/// but not yet yielded as `DataChannelEvent::OnMessage`.
const SCTP_RECEIVE_BUFFER_BOUND: usize = 1 << 20;

/// Per-peer outbound byte bound. C-facing try-writes may stage up to this much
/// in the sidecar, and the crate's own send buffer is configured to the same
/// limit so the async drain task is backpressured too.
const OUTBOUND_BUFFER_BOUND: usize = 1 << 20;

/// Capacity retained after an inbound burst drains, and the largest DataChannel
/// message the writer emits. This matches the 16 KiB steady buffers in the Zig
/// completion loop and stays within the WebRTC crate's documented browser-safe
/// message size. Larger writes are a byte stream here: they are split across
/// messages and concatenated again by the inbound queue.
const STEADY_BUFFER_BYTES: usize = 16 * 1024;

/// Inbound bytes staged from polled data-channel messages, drained by C-facing
/// reads. `closed` latches when the channel closes or the peer tears down, so a
/// reader parked on the condvar wakes and returns clean end of stream.
struct Inbound {
	buf: VecDeque<u8>,
	closed: bool,
}

/// Channel establishment state read by the non-blocking open check. `closed` is
/// also the peer's single terminal-transition authority.
struct OpenGate {
	open: bool,
	closed: bool,
}

struct Outbound {
	/// Bytes accepted from C try-writers but not yet handed to WebRTC. The C ABI
	/// is synchronous, while `DataChannel::try_send` still awaits the crate's
	/// async core lock, so this queue is the nonblocking boundary.
	buf: BytesMut,
	/// Includes bytes currently being sent by the async drain task, so the bound
	/// covers both queued and in-flight sidecar storage.
	queued_bytes: usize,
	closed: bool,
}

struct PeerShared {
	endpoint: Arc<EndpointInner>,
	id: usize,
	/// One admission edge for the asynchronous WebRTC close. Both explicit
	/// connection close and final peer release may arrive, but only the first
	/// starts work owned by the endpoint barrier.
	close_started: AtomicBool,
	/// Created immediately for an offerer, installed by the event handler for an
	/// answerer. Blocking writers clone it for direct `DataChannel::send`;
	/// try-writers use the bounded outbound staging queue.
	dc: Mutex<Option<Arc<dyn DataChannel>>>,
	inbound: Arc<(Mutex<Inbound>, Condvar)>,
	/// Signalled whenever a C read frees space in `inbound`, so the channel
	/// poller can resume after pausing at `INBOUND_BUFFER_BOUND`.
	drained: Arc<Notify>,
	outbound: Arc<Mutex<Outbound>>,
	/// Signalled when C try-write admits bytes, and when close releases a drain
	/// task waiting for work.
	outbound_ready: Arc<Notify>,
	open: Arc<Mutex<OpenGate>>,
	/// Locally gathered ICE candidates, serialized as JSON, awaiting the caller
	/// to drain and ferry to the far peer.
	local_candidates: Arc<Mutex<VecDeque<String>>>,
}
/// One shared WebRTC runtime and readiness namespace. Peers retain this inner
/// value so a misuse that releases the endpoint first cannot strand runtime
/// tasks, though the public contract still requires peers to be released first.
struct EndpointInner {
	rt: RuntimeOwner,
	/// Peer handles may release before their asynchronous crate-level close has
	/// completed. This owner survives them and makes endpoint release their one
	/// deterministic completion/failure barrier.
	close_tasks: Arc<CloseTasks>,
	/// The signaling/raw-peer subscription. Its event stream remains independent
	/// from the generic driver's subscription so neither consumer can steal the
	/// other's wake or readiness record.
	readiness: Arc<Readiness>,
	driver_readiness: Mutex<Option<Arc<Readiness>>>,
	next_peer_id: AtomicUsize,
	/// ICE server URLs every peer this endpoint creates offers to ICE. Empty is
	/// host candidates only, which reaches a peer on the same host or the same
	/// network and nothing beyond it.
	ice_servers: Vec<String>,
	/// Whether peers offer loopback ICE candidates, which is what connects two
	/// peers on one host with no STUN.
	include_loopback: bool,
}

impl EndpointInner {
	fn runtime(&self) -> &RuntimeOwner {
		&self.rt
	}

	fn signal(&self, subject: usize, events: u32) {
		self.readiness.signal(subject, events);
		if let Ok(slot) = self.driver_readiness.lock() {
			if let Some(readiness) = slot.as_ref() {
				readiness.signal(subject, events);
			}
		}
	}

	fn driver_readiness(&self) -> Option<Arc<Readiness>> {
		let mut slot = self.driver_readiness.lock().ok()?;
		if slot.is_none() {
			*slot = Readiness::new();
		}
		slot.clone()
	}
}

/// Opaque endpoint handle. One resident owns one of these and creates every
/// peer it multiplexes from it.
pub struct PancakeWebrtcEndpoint {
	inner: Arc<EndpointInner>,
}

/// One WebRTC peer: its shared endpoint, peer connection, the single data
/// channel once it exists, and the buffers the async callbacks feed. Opaque to C.
pub struct PancakeWebrtcPeer {
	shared: Arc<PeerShared>,
	pc: Arc<dyn PeerConnection>,
}

/// Create one endpoint: the runtime and readiness namespace shared by all peers
/// a resident multiplexes. Returns null if either resource cannot be created.
#[no_mangle]
pub extern "C" fn pancake_webrtc_sidecar_endpoint_new(
	config: *const PancakeWebrtcEndpointConfig,
) -> *mut PancakeWebrtcEndpoint {
	catch_unwind(AssertUnwindSafe(|| {
		if config.is_null() {
			return std::ptr::null_mut();
		}
		// Safety: the contract requires a readable config when non-null, and a
		// non-empty URL list to be that many readable bytes.
		let cfg = unsafe { &*config };
		let ice_servers: Vec<String> = if cfg.ice_servers.is_null() || cfg.ice_servers_len == 0 {
			Vec::new()
		} else {
			let bytes = unsafe { std::slice::from_raw_parts(cfg.ice_servers, cfg.ice_servers_len) };
			match std::str::from_utf8(bytes) {
				Ok(urls) => urls
					.split(',')
					.map(str::trim)
					.filter(|url| !url.is_empty())
					.map(str::to_owned)
					.collect(),
				Err(_) => return std::ptr::null_mut(),
			}
		};
		let readiness = match Readiness::new() {
			Some(readiness) => readiness,
			None => return std::ptr::null_mut(),
		};
		let workers = if cfg.worker_threads == 0 {
			WORKER_THREADS
		} else {
			cfg.worker_threads as usize
		};
		let rt = match tokio::runtime::Builder::new_multi_thread()
			.worker_threads(workers)
			.thread_name("pancake-webrtc")
			.enable_all()
			.build()
		{
			Ok(rt) => rt,
			Err(_) => return std::ptr::null_mut(),
		};
		Box::into_raw(Box::new(PancakeWebrtcEndpoint {
			inner: Arc::new(EndpointInner {
				rt: RuntimeOwner::new(rt),
				close_tasks: Arc::new(CloseTasks::new()),
				readiness,
				driver_readiness: Mutex::new(None),
				next_peer_id: AtomicUsize::new(1),
				ice_servers,
				include_loopback: cfg.include_loopback_candidates != 0,
			}),
		}))
	}))
	.unwrap_or(std::ptr::null_mut())
}

/// Borrow the endpoint's readiness fd. It remains valid until endpoint free.
#[no_mangle]
pub unsafe extern "C" fn pancake_webrtc_sidecar_endpoint_readiness_fd(endpoint: *const PancakeWebrtcEndpoint) -> i32 {
	catch_unwind(AssertUnwindSafe(|| {
		endpoint
			.as_ref()
			.map(|endpoint| endpoint.inner.readiness.reader.as_raw_fd())
			.unwrap_or(-1)
	}))
	.unwrap_or(-1)
}

/// Drain up to `out_cap` endpoint readiness records without allocation.
#[no_mangle]
pub unsafe extern "C" fn pancake_webrtc_sidecar_endpoint_drain_ready(
	endpoint: *const PancakeWebrtcEndpoint,
	out: *mut PancakeWebrtcReadyEvent,
	out_cap: usize,
) -> isize {
	catch_unwind(AssertUnwindSafe(|| {
		let endpoint = match endpoint.as_ref() {
			Some(endpoint) => endpoint,
			None => return ERR as isize,
		};
		if out.is_null() || out_cap == 0 {
			return 0;
		}
		let dest = std::slice::from_raw_parts_mut(out, out_cap);
		endpoint.inner.readiness.drain(dest) as isize
	}))
	.unwrap_or(ERR as isize)
}

/// Borrow an independent readiness descriptor for a generic driver provider.
/// The subscription is created lazily so raw-only endpoints pay no second
/// queue. Events published after this call are copied into both subscriptions.
#[no_mangle]
pub unsafe extern "C" fn pancake_webrtc_sidecar_endpoint_driver_readiness_fd(
	endpoint: *const PancakeWebrtcEndpoint,
) -> i32 {
	catch_unwind(AssertUnwindSafe(|| {
		endpoint
			.as_ref()
			.and_then(|endpoint| endpoint.inner.driver_readiness())
			.map(|readiness| readiness.reader.as_raw_fd())
			.unwrap_or(-1)
	}))
	.unwrap_or(-1)
}

/// Drain the generic driver's independent readiness subscription.
#[no_mangle]
pub unsafe extern "C" fn pancake_webrtc_sidecar_endpoint_drain_driver_ready(
	endpoint: *const PancakeWebrtcEndpoint,
	out: *mut PancakeWebrtcReadyEvent,
	out_cap: usize,
) -> isize {
	catch_unwind(AssertUnwindSafe(|| {
		let endpoint = match endpoint.as_ref() {
			Some(endpoint) => endpoint,
			None => return ERR as isize,
		};
		if out.is_null() || out_cap == 0 {
			return 0;
		}
		let readiness = match endpoint.inner.driver_readiness() {
			Some(readiness) => readiness,
			None => return ERR as isize,
		};
		let dest = std::slice::from_raw_parts_mut(out, out_cap);
		readiness.drain(dest) as isize
	}))
	.unwrap_or(ERR as isize)
}

/// Release an endpoint. Peers retain the runtime defensively, but callers must
/// still release every peer first so no readiness can outlive its owner.
#[no_mangle]
pub unsafe extern "C" fn pancake_webrtc_sidecar_endpoint_free(endpoint: *mut PancakeWebrtcEndpoint) -> i32 {
	if endpoint.is_null() {
		return OK;
	}
	teardown_status(|| {
		let endpoint = Box::from_raw(endpoint);
		let close_result = endpoint.inner.close_tasks.wait();
		drop(endpoint);
		close_result
	})
}

#[cfg(test)]
mod tests;
