//! The native WebRTC DataChannel sidecar (ADR-0089).
//!
//! This staticlib wraps WebRTC peers and their reliable, ordered
//! `RTCDataChannel`s behind a narrow C ABI, emitting
//! `libglowcap_webrtc_sidecar.a`. The Zig resident
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
//!   C-facing try-writes admit one bounded packet into the sidecar staging
//!   buffer, then an async drain task sends that packet as one DataChannel
//!   message without parking the caller's reactor thread.
//! * One channel, labelled `ocapn`, ordered and reliable, carries one bare
//!   OCapN codec frame per DataChannel message. The offerer creates it; the
//!   answerer receives it through `on_data_channel`.
//! * No panic crosses the FFI boundary: every entry point runs under
//!   `catch_unwind` and maps a panic to the function's error return.
//!
mod channel;
mod conn;
mod constants_gen;
mod peer_connection;
mod signaling;

use channel::*;

use std::collections::VecDeque;
use std::os::fd::AsRawFd;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, Weak};

use bytes::BytesMut;
use tokio::runtime::Handle;
use tokio::sync::Notify;
use webrtc::data_channel::{DataChannel, DataChannelEvent, RTCDataChannelInit};
use webrtc::peer_connection::{
	PeerConnection, PeerConnectionEventHandler, RTCIceCandidateInit, RTCIceServer, RTCPeerConnectionIceEvent,
	RTCPeerConnectionState, RTCSessionDescription,
};

use glowcap_sidecar_common::{RuntimeOwner, TaskBarrier};

/// The shared readiness channel, drained into this sidecar's own record layout.
type Readiness = glowcap_sidecar_common::Readiness<GlowcapWebrtcReadyEvent>;

/// The label of the one data channel a glowcap `webrtc` session runs over. Both
/// peers agree on it out of band; the offerer creates it under this name.
const CHANNEL_LABEL: &str = "ocapn";

/// Worker threads for one endpoint's runtime when the caller names none. Two is
/// enough for the callback and send work of a handful of channels, and it is a
/// per-endpoint cost, so a process holding many endpoints, or one endpoint
/// holding many peers, should say what it wants instead.
const WORKER_THREADS: usize = 2;

/// Maximum time the crate may retain one peer after glowcap has committed its
/// local close. WebRTC close is control-plane teardown, not application grace;
/// it must not make the endpoint's final release barrier unbounded. Fifteen
/// seconds matches the transport-level dead-peer bound used by the iroh
/// sidecar and is ample for SCTP/DTLS shutdown without licensing a stuck task.
const PEER_CLOSE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);

/// Return codes shared with the Zig resident and the header. `0` is success;
/// negatives name the failure family the resident maps to a Zig error.
const OK: i32 = 0;
const ERR: i32 = -1;

fn teardown_status<E>(f: impl FnOnce() -> Result<(), E>) -> i32 {
	match catch_unwind(AssertUnwindSafe(f)) {
		Ok(Ok(())) => OK,
		Ok(Err(_)) | Err(_) => ERR,
	}
}

/// Borrow a caller's handle for the length of one ABI call, answering `refused`
/// both for a null pointer and for a panic, which may never cross the C frame.
///
/// This is the sidecar's one trust boundary. Every `glowcap_webrtc_*` entry
/// point is handed a raw handle the C side got from the matching `*_new` and has
/// not yet freed, and this is the single place that assumption becomes a Rust
/// reference. Written once here, the argument for it is one thing to check
/// rather than one per entry point, and each entry point is left saying what it
/// does instead of restating who owns its pointer.
///
/// An out-parameter buffer is a separate assumption with its own guard, so it
/// stays at the call site that checks its capacity.
///
/// # Safety
/// `handle` is null, or points to a live value from the matching `*_new` that no
/// other call is freeing for the duration of this one.
unsafe fn borrowed<H, R: Copy>(handle: *const H, refused: R, body: impl FnOnce(&H) -> R) -> R {
	catch_unwind(AssertUnwindSafe(|| match unsafe { handle.as_ref() } {
		Some(handle) => body(handle),
		None => refused,
	}))
	.unwrap_or(refused)
}
/// A non-blocking call that cannot make progress yet: no candidate has gathered,
/// the channel is not open, or a bounded queue has no room. The resident re-arms
/// and retries, distinct from a hard error.
const WOULD_BLOCK: i32 = -2;
/// A string out-parameter whose buffer was too small; `*out_len` is set to the
/// length the caller must provide, and nothing is written.
const BUFFER_TOO_SMALL: i32 = -3;
/// A signaling string exceeded Glowcap's hard signaling cap; retrying with a
/// larger caller buffer cannot make it valid.
const SIGNAL_TOO_LARGE: i32 = -4;
/// A peer reached an orderly terminal state before opening.
const CLOSED: i32 = -5;

/// Readiness bits shared with the Zig resident and public C ABI. One drained
/// record may carry several bits for the same stable endpoint-scoped peer id.
const EV_OPEN: u32 = 1;
const EV_CANDIDATE: u32 = 2;
const EV_READABLE: u32 = 4;
const EV_WRITABLE: u32 = 8;
const EV_CLOSED: u32 = 16;

/// Borrowed UTF-8 text in the sidecar ABI.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct GlowcapWebrtcStringView {
	pub ptr: *const u8,
	pub len: usize,
}

/// One ICE server record. Each endpoint copies these borrowed fields into
/// endpoint-owned WebRTC configuration during construction.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct GlowcapWebrtcIceServer {
	pub urls: *const GlowcapWebrtcStringView,
	pub url_count: usize,
	pub username: GlowcapWebrtcStringView,
	pub credential: GlowcapWebrtcStringView,
}

/// One endpoint's configuration, passed by pointer so a new setting is a field
/// rather than a wider signature every caller has to agree on. What the setting
/// means is documented once, on the C ABI's `GlowcapWebrtcConfig`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct GlowcapWebrtcEndpointConfig {
	/// Borrowed ICE server records. Null or empty is host candidates only.
	pub ice_servers: *const GlowcapWebrtcIceServer,
	pub ice_server_count: usize,
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
pub struct GlowcapWebrtcReadyEvent {
	pub subject: usize,
	pub events: u32,
}

impl From<(usize, u32)> for GlowcapWebrtcReadyEvent {
	fn from((subject, events): (usize, u32)) -> Self {
		GlowcapWebrtcReadyEvent { subject, events }
	}
}

/// Largest DataChannel message glowcap sends or admits. The Zig transport
/// profile publishes the same ceiling so the Host narrows the session frame cap
/// before traffic starts.
const MAX_PACKET_BYTES: usize = constants_gen::TRANSPORT_WEBRTC_MAX_PACKET_BYTES;

/// Largest SDP string accepted through the signaling calls.
const MAX_SIGNAL_BYTES: usize = constants_gen::MAX_SIGNAL_BYTES;
/// Largest ICE-candidate JSON string accepted or retained by the signaling
/// calls. It aliases the signaling cap in Zig, but keeps the retained candidate
/// budget named at the Rust sidecar boundary.
const MAX_ICE_CANDIDATE_BYTES: usize = constants_gen::MAX_ICE_CANDIDATE_BYTES;

/// Locally gathered ICE candidates waiting for the signaling owner. These are
/// control-plane strings, not CapTP bytes, but they are still retained state.
const MAX_PENDING_LOCAL_CANDIDATES: usize = constants_gen::MAX_PENDING_ICE_CANDIDATES;
const LOCAL_CANDIDATE_QUEUE_BYTES: usize = constants_gen::PENDING_ICE_CANDIDATE_QUEUE_BYTES;

/// How many unread inbound packet bytes may pile up in the C-facing staging
/// buffer before the sidecar pauses its channel poller.
const INBOUND_BUFFER_BOUND: usize = constants_gen::DATA_CHANNEL_QUEUE_BYTES;

/// The SCTP receive window bound passed to `webrtc` 0.20. It is separate from
/// the C-facing staging bound above: the crate may hold bytes it has received
/// but not yet yielded as `DataChannelEvent::OnMessage`.
const SCTP_RECEIVE_BUFFER_BOUND: usize = constants_gen::SCTP_RECEIVE_BUFFER_BYTES;

/// Per-peer outbound byte bound. C-facing try-writes may stage up to this much
/// in the sidecar, and the crate's own send buffer is configured to the same
/// limit so the async drain task is backpressured too.
const OUTBOUND_BUFFER_BOUND: usize = constants_gen::DATA_CHANNEL_QUEUE_BYTES;

/// ICE configuration limits mirrored from the Zig WebRTC resident. They keep
/// the private sidecar FFI boundary bounded when it is called directly.
const MAX_ICE_SERVERS: usize = constants_gen::MAX_ICE_SERVERS;
const MAX_ICE_URLS_PER_SERVER: usize = constants_gen::MAX_ICE_URLS_PER_SERVER;
const MAX_ICE_URL_BYTES: usize = constants_gen::MAX_ICE_URL_BYTES;
const MAX_ICE_CREDENTIAL_BYTES: usize = constants_gen::MAX_ICE_CREDENTIAL_BYTES;

/// Inbound packets staged from polled data-channel messages, drained by
/// C-facing reads. Terminal state wakes parked readers; `failed` decides
/// whether an empty terminal read is EOF or `ERR`.
struct Inbound {
	packets: VecDeque<BytesMut>,
	queued_bytes: usize,
	closed: bool,
	failed: bool,
}

/// Channel establishment state read by the non-blocking open check. `closed`
/// and `failed` are the peer's single terminal transition and cause.
struct OpenGate {
	open: bool,
	closed: bool,
	failed: bool,
}

struct Outbound {
	/// Packets accepted from C try-writers but not yet handed to WebRTC. The C
	/// ABI is synchronous, while `DataChannel::send` still awaits the crate's
	/// async core lock, so this queue is the nonblocking boundary.
	packets: VecDeque<BytesMut>,
	/// Includes bytes currently being sent by the async drain task, so the bound
	/// covers both queued and in-flight sidecar storage.
	queued_bytes: usize,
	closed: bool,
}

struct LocalCandidates {
	items: VecDeque<String>,
	queued_bytes: usize,
}

impl LocalCandidates {
	fn new() -> Self {
		Self {
			items: VecDeque::new(),
			queued_bytes: 0,
		}
	}

	fn admit(&mut self, text: String) -> bool {
		if text.is_empty()
			|| text.len() > MAX_ICE_CANDIDATE_BYTES
			|| self.items.len() >= MAX_PENDING_LOCAL_CANDIDATES
			|| self.queued_bytes > LOCAL_CANDIDATE_QUEUE_BYTES.saturating_sub(text.len())
		{
			return false;
		}
		self.queued_bytes += text.len();
		self.items.push_back(text);
		true
	}

	fn release_front(&mut self) {
		if let Some(text) = self.items.pop_front() {
			self.queued_bytes = self.queued_bytes.saturating_sub(text.len());
		}
	}
}

struct PeerShared {
	endpoint: Arc<EndpointInner>,
	id: usize,
	/// One admission edge for the asynchronous WebRTC close. Both explicit
	/// connection close and final peer release may arrive, but only the first
	/// starts work owned by the endpoint barrier.
	close_started: AtomicBool,
	/// Weak to avoid the handler cycle: PeerConnection owns its handler, the
	/// handler owns PeerShared, and failure publication still needs to start the
	/// endpoint-owned close task.
	pc: Mutex<Option<Weak<dyn PeerConnection>>>,
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
	local_candidates: Arc<Mutex<LocalCandidates>>,
}
/// One shared WebRTC runtime and readiness namespace. Peers retain this inner
/// value so a misuse that releases the endpoint first cannot strand runtime
/// tasks, though the public contract still requires peers to be released first.
struct EndpointInner {
	rt: RuntimeOwner,
	/// Peer handles may release before their asynchronous crate-level close has
	/// completed. This owner survives them and makes endpoint release their one
	/// deterministic completion/failure barrier.
	close_tasks: Arc<TaskBarrier>,
	/// The signaling/raw-peer subscription. Its event stream remains independent
	/// from the generic driver's subscription so neither consumer can steal the
	/// other's wake or readiness record.
	readiness: Arc<Readiness>,
	driver_readiness: Mutex<Option<Arc<Readiness>>>,
	next_peer_id: AtomicUsize,
	/// ICE server records every peer this endpoint creates offers to ICE. Empty
	/// is host candidates only, which reaches a peer on the same host or the same
	/// network and nothing beyond it.
	ice_servers: Vec<RTCIceServer>,
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
		if let Ok(slot) = self.driver_readiness.lock()
			&& let Some(readiness) = slot.as_ref()
		{
			readiness.signal(subject, events);
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

unsafe fn view_text(view: GlowcapWebrtcStringView, max_len: usize) -> Option<String> {
	if view.len == 0 {
		return Some(String::new());
	}
	if view.len > max_len {
		return None;
	}
	if view.ptr.is_null() {
		return None;
	}
	// SAFETY: the caller lends the view for this call, and the empty, oversized,
	// and null cases all returned above.
	std::str::from_utf8(unsafe { std::slice::from_raw_parts(view.ptr, view.len) })
		.ok()
		.map(str::to_owned)
}

fn ice_url_is_turn(url: &str) -> Option<bool> {
	if starts_with_ascii_ignore_case(url, "stun:") || starts_with_ascii_ignore_case(url, "stuns:") {
		return Some(false);
	}
	if starts_with_ascii_ignore_case(url, "turn:") || starts_with_ascii_ignore_case(url, "turns:") {
		return Some(true);
	}
	None
}

fn starts_with_ascii_ignore_case(value: &str, prefix: &str) -> bool {
	value
		.get(..prefix.len())
		.is_some_and(|head| head.eq_ignore_ascii_case(prefix))
}

unsafe fn ice_servers_from_config(cfg: &GlowcapWebrtcEndpointConfig) -> Option<Vec<RTCIceServer>> {
	if cfg.ice_server_count == 0 {
		return Some(Vec::new());
	}
	if cfg.ice_server_count > MAX_ICE_SERVERS {
		return None;
	}
	if cfg.ice_servers.is_null() {
		return None;
	}
	// SAFETY: the caller lends the whole configuration tree for this call, and
	// each count is bounded and each pointer null-checked before it is read.
	let records = unsafe { std::slice::from_raw_parts(cfg.ice_servers, cfg.ice_server_count) };
	let mut out = Vec::with_capacity(records.len());
	for record in records {
		if record.url_count == 0 || record.url_count > MAX_ICE_URLS_PER_SERVER || record.urls.is_null() {
			return None;
		}
		let url_views = unsafe { std::slice::from_raw_parts(record.urls, record.url_count) };
		let mut urls = Vec::with_capacity(url_views.len());
		let mut has_turn = false;
		for url in url_views {
			let text = unsafe { view_text(*url, MAX_ICE_URL_BYTES) }?;
			if text.is_empty() {
				return None;
			}
			has_turn |= ice_url_is_turn(&text)?;
			urls.push(text);
		}
		let username = unsafe { view_text(record.username, MAX_ICE_CREDENTIAL_BYTES) }?;
		let credential = unsafe { view_text(record.credential, MAX_ICE_CREDENTIAL_BYTES) }?;
		let has_credentials = !username.is_empty() || !credential.is_empty();
		if (!has_turn && has_credentials) || (has_turn && (username.is_empty() || credential.is_empty())) {
			return None;
		}
		out.push(RTCIceServer {
			urls,
			username,
			credential,
		});
	}
	Some(out)
}

/// Opaque endpoint handle. One resident owns one of these and creates every
/// peer it multiplexes from it.
pub struct GlowcapWebrtcEndpoint {
	inner: Arc<EndpointInner>,
}

/// One WebRTC peer: its shared endpoint, peer connection, the single data
/// channel once it exists, and the buffers the async callbacks feed. Opaque to C.
pub struct GlowcapWebrtcPeer {
	shared: Arc<PeerShared>,
	pc: Arc<dyn PeerConnection>,
}

/// Create one endpoint: the runtime and readiness namespace shared by all peers
/// a resident multiplexes. Returns null if either resource cannot be created.
///
/// # Safety
/// `config` must point to a readable configuration whose nested ICE-server
/// arrays satisfy their documented pointer and length contracts.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_endpoint_new(
	config: *const GlowcapWebrtcEndpointConfig,
) -> *mut GlowcapWebrtcEndpoint {
	catch_unwind(AssertUnwindSafe(|| {
		if config.is_null() {
			return std::ptr::null_mut();
		}
		// Safety: the caller supplies readable memory; `ice_servers_from_config`
		// bounds every count and length before forming nested slices.
		let cfg = unsafe { &*config };
		let ice_servers = match unsafe { ice_servers_from_config(cfg) } {
			Some(servers) => servers,
			None => return std::ptr::null_mut(),
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
			.thread_name("glowcap-webrtc")
			.enable_all()
			.build()
		{
			Ok(rt) => rt,
			Err(_) => return std::ptr::null_mut(),
		};
		Box::into_raw(Box::new(GlowcapWebrtcEndpoint {
			inner: Arc::new(EndpointInner {
				rt: RuntimeOwner::new(rt),
				close_tasks: Arc::new(TaskBarrier::new()),
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
///
/// # Safety
/// `endpoint` must be a live endpoint handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_endpoint_readiness_fd(endpoint: *const GlowcapWebrtcEndpoint) -> i32 {
	// SAFETY: the handle contract `borrowed` states.
	unsafe { borrowed(endpoint, -1, |endpoint| endpoint.inner.readiness.reader.as_raw_fd()) }
}

/// Drain up to `out_cap` endpoint readiness records without allocation.
///
/// # Safety
/// `endpoint` must be live. When `out_cap` is nonzero, `out` must address that
/// many writable records.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_endpoint_drain_ready(
	endpoint: *const GlowcapWebrtcEndpoint,
	out: *mut GlowcapWebrtcReadyEvent,
	out_cap: usize,
) -> isize {
	// Outside the `unsafe` block below, so the caller-buffer projection is still
	// marked where it happens rather than absorbed into the handle's block.
	let drain = |endpoint: &GlowcapWebrtcEndpoint| {
		if out.is_null() || out_cap == 0 {
			return 0;
		}
		// SAFETY: the caller declares `out_cap` writable records at `out`, and
		// the null and zero-capacity cases went to the arm above.
		let dest = unsafe { std::slice::from_raw_parts_mut(out, out_cap) };
		endpoint.inner.readiness.drain(dest) as isize
	};
	// SAFETY: the handle contract `borrowed` states.
	unsafe { borrowed(endpoint, ERR as isize, drain) }
}

/// Borrow an independent readiness descriptor for a generic driver provider.
/// The subscription is created lazily so raw-only endpoints pay no second
/// queue. Events published after this call are copied into both subscriptions.
///
/// # Safety
/// `endpoint` must be a live endpoint handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_endpoint_driver_readiness_fd(
	endpoint: *const GlowcapWebrtcEndpoint,
) -> i32 {
	// SAFETY: the handle contract `borrowed` states.
	unsafe {
		borrowed(endpoint, -1, |endpoint| {
			endpoint
				.inner
				.driver_readiness()
				.map(|readiness| readiness.reader.as_raw_fd())
				.unwrap_or(-1)
		})
	}
}

/// Drain the generic driver's independent readiness subscription.
///
/// # Safety
/// `endpoint` must be live. When `out_cap` is nonzero, `out` must address that
/// many writable records.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_endpoint_drain_driver_ready(
	endpoint: *const GlowcapWebrtcEndpoint,
	out: *mut GlowcapWebrtcReadyEvent,
	out_cap: usize,
) -> isize {
	// Outside the `unsafe` block below, so the caller-buffer projection is still
	// marked where it happens rather than absorbed into the handle's block.
	let drain = |endpoint: &GlowcapWebrtcEndpoint| {
		if out.is_null() || out_cap == 0 {
			return 0;
		}
		let readiness = match endpoint.inner.driver_readiness() {
			Some(readiness) => readiness,
			None => return ERR as isize,
		};
		// SAFETY: the caller declares `out_cap` writable records at `out`, and
		// the null and zero-capacity cases went to the arm above.
		let dest = unsafe { std::slice::from_raw_parts_mut(out, out_cap) };
		readiness.drain(dest) as isize
	};
	// SAFETY: the handle contract `borrowed` states.
	unsafe { borrowed(endpoint, ERR as isize, drain) }
}

/// Release an endpoint. Peers retain the runtime defensively, but callers must
/// still release every peer first so no readiness can outlive its owner.
///
/// # Safety
/// `endpoint` must be null or an owned endpoint handle not previously freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_webrtc_sidecar_endpoint_free(endpoint: *mut GlowcapWebrtcEndpoint) -> i32 {
	if endpoint.is_null() {
		return OK;
	}
	teardown_status(|| {
		// SAFETY: an unfreed handle from `endpoint_new`, with null refused
		// above, so this frame is its last owner.
		let endpoint = unsafe { Box::from_raw(endpoint) };
		let close_result = endpoint.inner.close_tasks.wait();
		drop(endpoint);
		close_result
	})
}

#[cfg(test)]
mod tests;
