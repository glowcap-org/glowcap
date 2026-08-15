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
use std::collections::{HashMap, VecDeque};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};

use bytes::BytesMut;
use tokio::runtime::{Handle, Runtime};
use tokio::sync::Notify;
use webrtc::data_channel::{DataChannel, DataChannelEvent, RTCDataChannelInit};
use webrtc::error::{Error as WebrtcError, Result as WebrtcResult};
use webrtc::peer_connection::{
	register_default_interceptors, MediaEngine, PeerConnection, PeerConnectionBuilder, PeerConnectionEventHandler,
	RTCConfigurationBuilder, RTCIceCandidateInit, RTCIceServer, RTCPeerConnectionIceEvent, RTCPeerConnectionState,
	RTCSessionDescription, Registry, SettingEngine,
};
use webrtc::runtime::TokioRuntime;

/// The label of the one data channel a pancake `webrtc` session runs over. Both
/// peers agree on it out of band; the offerer creates it under this name.
const CHANNEL_LABEL: &str = "ocapn";

/// Worker threads for one endpoint's runtime when the caller names none. Two is
/// enough for the callback and send work of a handful of channels, and it is a
/// per-endpoint cost, so a process holding many endpoints, or one endpoint
/// holding many peers, should say what it wants instead.
const WORKER_THREADS: usize = 2;

/// Return codes shared with the Zig resident and the header. `0` is success;
/// negatives name the failure family the resident maps to a Zig error.
const OK: i32 = 0;
const ERR: i32 = -1;

fn teardown_status(f: impl FnOnce()) -> i32 {
	match catch_unwind(AssertUnwindSafe(f)) {
		Ok(()) => OK,
		Err(_) => ERR,
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

/// One endpoint's readiness channel: a non-blocking self-pipe plus the
/// authoritative queue of pending records. Wake bytes are coalescing hints;
/// records, not byte counts, carry state.
struct Readiness {
	reader: UnixStream,
	writer: Mutex<UnixStream>,
	state: Mutex<ReadyState>,
}

struct ReadyState {
	subjects: VecDeque<usize>,
	events: HashMap<usize, u32>,
}

impl Readiness {
	fn new() -> Option<Arc<Readiness>> {
		let (reader, writer) = UnixStream::pair().ok()?;
		reader.set_nonblocking(true).ok()?;
		writer.set_nonblocking(true).ok()?;
		// Only the read half crosses the sidecar boundary. Make misuse fail at
		// the fd instead of allowing a caller to manufacture spurious wakes.
		reader.shutdown(std::net::Shutdown::Write).ok()?;
		Some(Arc::new(Readiness {
			reader,
			writer: Mutex::new(writer),
			state: Mutex::new(ReadyState {
				subjects: VecDeque::new(),
				events: HashMap::new(),
			}),
		}))
	}

	fn signal(&self, subject: usize, events: u32) {
		let mut state = self.state.lock().unwrap();
		if let Some(pending) = state.events.get_mut(&subject) {
			*pending |= events;
		} else {
			state.events.insert(subject, events);
			state.subjects.push_back(subject);
		}
		drop(state);
		self.nudge();
	}

	/// Best-effort self-pipe wake used both when publishing an event and when a
	/// short drain leaves queued records. `WouldBlock` is safe to discard because
	/// it means the pipe is full of unread bytes, which makes the read fd already
	/// poll-readable. An interrupted write has no such guarantee and is retried.
	fn nudge(&self) {
		if let Ok(mut writer) = self.writer.lock() {
			loop {
				match writer.write(&[1]) {
					Ok(_) => return,
					Err(err) if err.kind() == std::io::ErrorKind::Interrupted => continue,
					Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => return,
					// The read half is gone, so there is no live poller left to wake.
					Err(_) => return,
				}
			}
		}
	}

	/// Clear coalesced wake bytes before draining authoritative records. A signal
	/// racing this operation either joins this drain or leaves a byte for the next
	/// poll. A short record drain re-nudges the fd for its remaining backlog.
	fn drain(&self, dest: &mut [PancakeWebrtcReadyEvent]) -> usize {
		let mut wake = [0u8; 256];
		let mut reader = &self.reader;
		loop {
			match reader.read(&mut wake) {
				Ok(0) => break,
				Ok(_) => {}
				Err(err) if err.kind() == std::io::ErrorKind::Interrupted => continue,
				Err(_) => break,
			}
		}

		let mut state = self.state.lock().unwrap();
		let count = dest.len().min(state.subjects.len());
		for slot in dest.iter_mut().take(count) {
			let subject = state.subjects.pop_front().unwrap();
			let events = state.events.remove(&subject).unwrap();
			*slot = PancakeWebrtcReadyEvent { subject, events };
		}
		let remaining = !state.subjects.is_empty();
		drop(state);
		if remaining {
			self.nudge();
		}
		count
	}
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

/// Own the Tokio runtime behind an endpoint. `Runtime::drop` panics when it runs
/// inside an ambient async context; `shutdown_background` is explicitly safe
/// there. Peer teardown closes its connection first, so background shutdown is
/// only the non-parking final reap, not the peer's close protocol.
struct RuntimeOwner(Option<Runtime>);

impl RuntimeOwner {
	fn get(&self) -> &Runtime {
		self.0.as_ref().unwrap()
	}
}

impl Drop for RuntimeOwner {
	fn drop(&mut self) {
		if let Some(rt) = self.0.take() {
			rt.shutdown_background();
		}
	}
}

/// One shared WebRTC runtime and readiness namespace. Peers retain this inner
/// value so a misuse that releases the endpoint first cannot strand runtime
/// tasks, though the public contract still requires peers to be released first.
struct EndpointInner {
	rt: RuntimeOwner,
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
	fn runtime(&self) -> &Runtime {
		self.rt.get()
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

/// Build the data-channel-only WebRTC API: default codecs and interceptors,
/// plus loopback ICE candidates so two peers on one host connect with no STUN.
///
/// `ice_servers` is the endpoint's, and it decides how far this peer can reach.
/// Empty offers host candidates only, which is enough for one host or one
/// network; a deployment crossing NAT names STUN servers through the
/// endpoint's config.
fn build_peer_connection(
	rt: &Runtime,
	handler: Arc<dyn PeerConnectionEventHandler>,
	ice_servers: &[String],
	include_loopback: bool,
) -> WebrtcResult<Arc<dyn PeerConnection>> {
	let mut setting_engine = SettingEngine::default();
	setting_engine.set_include_loopback_candidate(include_loopback);

	let mut media_engine = MediaEngine::default();
	media_engine.register_default_codecs()?;
	let registry = register_default_interceptors(Registry::new(), &mut media_engine)?;
	let config = RTCConfigurationBuilder::new()
		.with_ice_servers(if ice_servers.is_empty() {
			Vec::new()
		} else {
			vec![RTCIceServer {
				urls: ice_servers.to_vec(),
				..Default::default()
			}]
		})
		.build();
	let udp_addrs = udp_bind_addrs(include_loopback);
	let pc = rt.block_on(async move {
		let pc = PeerConnectionBuilder::new()
			.with_configuration(config)
			.with_media_engine(media_engine)
			.with_interceptor_registry(registry)
			.with_setting_engine(setting_engine)
			.with_handler(handler)
			.with_runtime(Arc::new(TokioRuntime))
			.with_udp_addrs(udp_addrs)
			.with_sctp_receive_buffer_size(SCTP_RECEIVE_BUFFER_BOUND as u32)
			.with_data_channel_send_buffer_limit(OUTBOUND_BUFFER_BOUND)
			.build()
			.await?;
		Ok::<Arc<dyn PeerConnection>, WebrtcError>(Arc::new(pc))
	})?;
	Ok(pc)
}

fn udp_bind_addrs(include_loopback: bool) -> Vec<String> {
	let mut addrs = vec!["0.0.0.0:0".to_owned()];
	if include_loopback {
		addrs.push("127.0.0.1:0".to_owned());
	}
	addrs
}

#[derive(Clone)]
struct PeerEvents {
	shared: Arc<PeerShared>,
	runtime: Handle,
}

#[async_trait::async_trait]
impl PeerConnectionEventHandler for PeerEvents {
	async fn on_ice_candidate(&self, event: RTCPeerConnectionIceEvent) {
		let init = match event.candidate.to_json() {
			Ok(init) => init,
			Err(_) => return,
		};
		if init.candidate.is_empty() {
			return;
		}
		if let Ok(text) = serde_json::to_string(&init) {
			self.shared.local_candidates.lock().unwrap().push_back(text);
			self.shared.endpoint.signal(self.shared.id, EV_CANDIDATE);
		}
	}

	async fn on_connection_state_change(&self, state: RTCPeerConnectionState) {
		// This is the only terminal path for a peer that never opens a channel:
		// ICE can fail before any DataChannel close event exists. The once-only
		// publication path is unit-tested; forcing a real ICE timeout would make
		// the sidecar suite wait on network retry timers.
		if matches!(state, RTCPeerConnectionState::Failed | RTCPeerConnectionState::Closed) {
			publish_peer_closed(&self.shared);
		}
	}

	async fn on_data_channel(&self, dc: Arc<dyn DataChannel>) {
		let shared = self.shared.clone();
		self.runtime.spawn(async move {
			install_remote_channel(shared, dc).await;
		});
	}
}

async fn install_remote_channel(shared: Arc<PeerShared>, dc: Arc<dyn DataChannel>) {
	let label = match dc.label().await {
		Ok(label) => label,
		Err(_) => {
			publish_peer_closed(&shared);
			return;
		}
	};
	if label != CHANNEL_LABEL {
		// Only the `ocapn` channel is this transport. Any other label is a
		// peer-created side channel, not a CapTP byte source.
		let _ = dc.close().await;
		return;
	}
	let claimed = {
		let mut slot = shared.dc.lock().unwrap();
		if slot.is_some() {
			false
		} else {
			*slot = Some(dc.clone());
			true
		}
	};
	if claimed {
		wire_channel(dc, shared);
	} else {
		// A peer owns exactly one `ocapn` channel. A second one would interleave
		// bytes into the same inbound queue and compete for the one outbound writer,
		// so refuse it at the transport edge.
		let _ = dc.close().await;
	}
}

/// Wire one channel to the peer's blocking latches and endpoint readiness
/// surface. Used for both the offerer's created channel and the answerer's
/// received one.
fn wire_channel(dc: Arc<dyn DataChannel>, shared: Arc<PeerShared>) {
	let handle = shared.endpoint.runtime().handle().clone();
	handle.spawn(pump_channel(dc.clone(), shared.clone()));
	handle.spawn(drain_outbound(dc, shared));
}

async fn pump_channel(dc: Arc<dyn DataChannel>, shared: Arc<PeerShared>) {
	while let Some(event) = dc.poll().await {
		match event {
			DataChannelEvent::OnOpen => {
				if shared.inbound.0.lock().unwrap().closed {
					return;
				}
				{
					let mut gate = shared.open.lock().unwrap();
					if gate.closed {
						return;
					}
					gate.open = true;
				}
				shared.endpoint.signal(shared.id, EV_OPEN | EV_WRITABLE);
			}
			DataChannelEvent::OnMessage(msg) => {
				let incoming_len = msg.data.len();
				if incoming_len == 0 {
					continue;
				}
				if incoming_len > INBOUND_BUFFER_BOUND {
					publish_peer_closed(&shared);
					let _ = dc.close().await;
					return;
				}
				if !await_inbound_room(&shared.inbound, &shared.drained, incoming_len).await {
					return;
				}
				let (lock, cvar) = &*shared.inbound;
				lock.lock().unwrap().buf.extend(msg.data.iter().copied());
				cvar.notify_all();
				shared.endpoint.signal(shared.id, EV_READABLE);
			}
			DataChannelEvent::OnBufferedAmountLow => {}
			DataChannelEvent::OnClose | DataChannelEvent::OnClosing | DataChannelEvent::OnError => {
				publish_peer_closed(&shared);
				return;
			}
			DataChannelEvent::OnBufferedAmountHigh => {}
		}
	}
	publish_peer_closed(&shared);
}

/// Move C-admitted writes through the async WebRTC API without parking the
/// caller's reactor thread. `queued_bytes` includes each in-flight batch until
/// the send finishes, so the sidecar bound covers both queued and active send
/// storage.
async fn drain_outbound(dc: Arc<dyn DataChannel>, shared: Arc<PeerShared>) {
	loop {
		let mut batch = loop {
			let next = {
				let mut state = shared.outbound.lock().unwrap();
				if state.closed {
					return;
				}
				if state.buf.is_empty() {
					None
				} else {
					Some(std::mem::take(&mut state.buf))
				}
			};
			if let Some(batch) = next {
				break batch;
			}
			shared.outbound_ready.notified().await;
		};

		while !batch.is_empty() {
			let len = batch.len().min(STEADY_BUFFER_BYTES);
			let bytes = batch.split_to(len);
			if dc.send(bytes).await.is_err() {
				publish_peer_closed(&shared);
				return;
			}
			let writable = {
				let mut state = shared.outbound.lock().unwrap();
				state.queued_bytes = state.queued_bytes.saturating_sub(len);
				state.queued_bytes < OUTBOUND_BUFFER_BOUND
			};
			if writable {
				shared.endpoint.signal(shared.id, EV_WRITABLE);
			}
		}
	}
}

/// Park until the reader has taken enough out of `inbound` to leave room for the
/// whole incoming message under `INBOUND_BUFFER_BOUND`. Returns false once the
/// channel has closed, or when a single message is larger than the inbound
/// budget and cannot be admitted without breaking the bound.
///
/// The `webrtc` 0.20 channel pump awaits this before appending the message it
/// just polled and before polling another one. That serialization is the
/// invariant which makes the check and later append one-message-at-a-time:
/// parking here stops draining the crate's event stream, and the SCTP receive
/// window bounds the bytes the far peer can have in flight.
async fn await_inbound_room(inbound: &Arc<(Mutex<Inbound>, Condvar)>, drained: &Notify, incoming_len: usize) -> bool {
	if incoming_len > INBOUND_BUFFER_BOUND {
		return false;
	}
	loop {
		{
			let (lock, _) = &**inbound;
			let guard = lock.lock().unwrap();
			if guard.closed {
				return false;
			}
			if guard.buf.len() <= INBOUND_BUFFER_BOUND - incoming_len {
				return true;
			}
		}
		// `notify_one` leaves a permit behind when nothing is parked yet, so a
		// reader that drains between the check above and this await still wakes
		// us.
		drained.notified().await;
	}
}

/// Close the inbound staging area and wake every blocking or async waiter.
/// Returns true only for the first terminal transition, so `EV_CLOSED` is
/// emitted once.
fn mark_peer_closed(shared: &PeerShared) -> bool {
	let first = {
		let mut state = shared.open.lock().unwrap();
		let first = !state.closed;
		state.closed = true;
		first
	};
	{
		let (lock, cvar) = &*shared.inbound;
		let mut state = lock.lock().unwrap();
		state.closed = true;
		cvar.notify_all();
	}
	shared.drained.notify_waiters();
	shared.drained.notify_one();
	shared.outbound.lock().unwrap().closed = true;
	shared.outbound_ready.notify_waiters();
	shared.outbound_ready.notify_one();
	first
}

/// Publish the peer's terminal readiness exactly once, regardless of whether
/// close arrives from the channel poller, a failed send, explicit close, or
/// handle release. `OpenGate.closed` is the single terminal authority.
fn publish_peer_closed(shared: &PeerShared) {
	if mark_peer_closed(shared) {
		shared.endpoint.signal(shared.id, EV_CLOSED);
	}
}

/// Copy a contiguous prefix out of the inbound staging deque. When a burst drains,
/// return its excess capacity so one slow-reader episode does not pin the
/// 1 MiB high-water mark for the peer's lifetime.
fn take_inbound(state: &mut Inbound, dest: &mut [u8]) -> usize {
	let n = state.buf.len().min(dest.len());
	let (front, back) = state.buf.as_slices();
	let from_front = front.len().min(n);
	dest[..from_front].copy_from_slice(&front[..from_front]);
	if from_front < n {
		dest[from_front..n].copy_from_slice(&back[..n - from_front]);
	}
	state.buf.drain(..n);
	if state.buf.is_empty() && state.buf.capacity() > STEADY_BUFFER_BYTES {
		state.buf.shrink_to(STEADY_BUFFER_BYTES);
	}
	n
}

/// Admit as much of one try-write as currently fits. Returning a prefix instead
/// of rejecting every slice larger than the bound guarantees that a caller which
/// advances by the returned count can always make progress once the drain frees
/// room.
fn enqueue_outbound(state: &mut Outbound, bytes: &[u8]) -> isize {
	if state.closed {
		return ERR as isize;
	}
	if bytes.is_empty() {
		return 0;
	}
	let room = OUTBOUND_BUFFER_BOUND.saturating_sub(state.queued_bytes);
	if room == 0 {
		return WOULD_BLOCK as isize;
	}
	let accepted = room.min(bytes.len());
	state.buf.extend_from_slice(&bytes[..accepted]);
	state.queued_bytes += accepted;
	accepted as isize
}

/// Start the crate-level close without waiting on the caller's thread. Terminal
/// state and readiness are published before this runs, so the task only performs
/// WebRTC teardown; it owns an `Arc` to the connection until that finishes.
fn close_peer_async(peer: &PancakeWebrtcPeer) {
	let pc = peer.pc.clone();
	peer.shared.endpoint.runtime().handle().spawn(async move {
		let _ = pc.close().await;
	});
}

fn mint_peer_id(endpoint: &EndpointInner) -> Option<usize> {
	endpoint
		.next_peer_id
		.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |id| id.checked_add(1))
		.ok()
		.filter(|id| *id != 0)
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
				rt: RuntimeOwner(Some(rt)),
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
	teardown_status(|| drop(Box::from_raw(endpoint)))
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
pub unsafe extern "C" fn pancake_webrtc_sidecar_peer_new(
	endpoint: *mut PancakeWebrtcEndpoint,
	is_offerer: i32,
) -> *mut PancakeWebrtcPeer {
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
			dc: Mutex::new(None),
			inbound: Arc::new((
				Mutex::new(Inbound {
					buf: VecDeque::new(),
					closed: false,
				}),
				Condvar::new(),
			)),
			drained: Arc::new(Notify::new()),
			outbound: Arc::new(Mutex::new(Outbound {
				buf: BytesMut::new(),
				queued_bytes: 0,
				closed: false,
			})),
			outbound_ready: Arc::new(Notify::new()),
			open: Arc::new(Mutex::new(OpenGate {
				open: false,
				closed: false,
			})),
			local_candidates: Arc::new(Mutex::new(VecDeque::new())),
		});
		let handler = Arc::new(PeerEvents {
			shared: shared.clone(),
			runtime: endpoint.runtime().handle().clone(),
		});
		let pc = match build_peer_connection(
			endpoint.runtime(),
			handler,
			&endpoint.ice_servers,
			endpoint.include_loopback,
		) {
			Ok(pc) => pc,
			Err(_) => return std::ptr::null_mut(),
		};

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

		let peer = Box::new(PancakeWebrtcPeer { shared, pc });
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
		let offer = match peer.shared.endpoint.runtime().block_on(peer.pc.create_offer(None)) {
			Ok(offer) => offer,
			Err(_) => return ERR,
		};
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
		let answer = match peer.shared.endpoint.runtime().block_on(peer.pc.create_answer(None)) {
			Ok(answer) => answer,
			Err(_) => return ERR,
		};
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
		let mut queue = peer.shared.local_candidates.lock().unwrap();
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
	let _ = catch_unwind(AssertUnwindSafe(|| {
		if let Some(peer) = peer.as_ref() {
			// Release a poller parked for room first. Nobody will drain the
			// buffer now, and closing while a runtime task still holds a message
			// makes shutdown depend on the crate's internals to make progress.
			publish_peer_closed(&peer.shared);
			close_peer_async(peer);
		}
	}));
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
	let _ = catch_unwind(AssertUnwindSafe(|| {
		let peer = Box::from_raw(peer);
		// Same ordering as `conn_close`: free a parked poller before closing.
		publish_peer_closed(&peer.shared);
		close_peer_async(&peer);
		// `peer` drops here; the endpoint owns the shared runtime.
	}));
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::io::Read;
	use std::time::Duration;

	fn full_inbound() -> Arc<(Mutex<Inbound>, Condvar)> {
		Arc::new((
			Mutex::new(Inbound {
				buf: std::iter::repeat(0u8).take(INBOUND_BUFFER_BOUND).collect(),
				closed: false,
			}),
			Condvar::new(),
		))
	}

	fn test_shared(
		id: usize,
		inbound: Arc<(Mutex<Inbound>, Condvar)>,
		open: Arc<Mutex<OpenGate>>,
		drained: Arc<Notify>,
		readiness: Arc<Readiness>,
	) -> Arc<PeerShared> {
		let rt = tokio::runtime::Builder::new_multi_thread()
			.worker_threads(1)
			.enable_all()
			.build()
			.unwrap();
		Arc::new(PeerShared {
			endpoint: Arc::new(EndpointInner {
				rt: RuntimeOwner(Some(rt)),
				readiness,
				driver_readiness: Mutex::new(None),
				next_peer_id: AtomicUsize::new(id + 1),
				ice_servers: Vec::new(),
				include_loopback: true,
			}),
			id,
			dc: Mutex::new(None),
			inbound,
			drained,
			outbound: Arc::new(Mutex::new(Outbound {
				buf: BytesMut::new(),
				queued_bytes: 0,
				closed: false,
			})),
			outbound_ready: Arc::new(Notify::new()),
			open,
			local_candidates: Arc::new(Mutex::new(VecDeque::new())),
		})
	}

	#[tokio::test]
	async fn a_full_buffer_makes_the_next_message_wait_for_the_reader() {
		// Without this the far peer could send for as long as it liked and the
		// buffer would keep growing, so one partner could exhaust our memory.
		let inbound = full_inbound();
		let drained = Arc::new(Notify::new());

		let waiting = tokio::spawn({
			let inbound = inbound.clone();
			let drained = drained.clone();
			async move { await_inbound_room(&inbound, &drained, 1).await }
		});

		// Still parked: nothing has read yet.
		tokio::time::sleep(Duration::from_millis(50)).await;
		assert!(!waiting.is_finished());

		// A read frees space, exactly as `conn_read` does.
		inbound.0.lock().unwrap().buf.drain(..1024);
		drained.notify_one();
		assert!(waiting.await.unwrap());
	}

	#[tokio::test]
	async fn a_message_waits_until_the_whole_message_fits_under_the_inbound_bound() {
		let inbound = Arc::new((
			Mutex::new(Inbound {
				buf: std::iter::repeat(0u8).take(INBOUND_BUFFER_BOUND - 8).collect(),
				closed: false,
			}),
			Condvar::new(),
		));
		let drained = Arc::new(Notify::new());

		let waiting = tokio::spawn({
			let inbound = inbound.clone();
			let drained = drained.clone();
			async move { await_inbound_room(&inbound, &drained, 16).await }
		});

		tokio::time::sleep(Duration::from_millis(50)).await;
		assert!(!waiting.is_finished());

		inbound.0.lock().unwrap().buf.drain(..8);
		drained.notify_one();
		assert!(waiting.await.unwrap());
	}

	#[tokio::test]
	async fn an_oversized_message_cannot_enter_inbound_staging() {
		let inbound = Arc::new((
			Mutex::new(Inbound {
				buf: VecDeque::new(),
				closed: false,
			}),
			Condvar::new(),
		));
		let drained = Notify::new();

		assert!(!await_inbound_room(&inbound, &drained, INBOUND_BUFFER_BOUND + 1).await);
	}

	#[tokio::test]
	async fn closing_releases_a_message_that_was_waiting_for_room() {
		// Otherwise the handler parks forever on a channel nobody will drain.
		let inbound = full_inbound();
		let drained = Arc::new(Notify::new());

		let waiting = tokio::spawn({
			let inbound = inbound.clone();
			let drained = drained.clone();
			async move { await_inbound_room(&inbound, &drained, 1).await }
		});

		tokio::time::sleep(Duration::from_millis(50)).await;
		assert!(!waiting.is_finished());

		let open = Arc::new(Mutex::new(OpenGate {
			open: false,
			closed: false,
		}));
		let readiness = Readiness::new().unwrap();
		let shared = test_shared(7, inbound.clone(), open, drained, readiness);
		publish_peer_closed(&shared);
		assert!(!waiting.await.unwrap());
	}

	#[tokio::test]
	async fn a_buffer_with_room_does_not_wait() {
		let inbound = Arc::new((
			Mutex::new(Inbound {
				buf: VecDeque::new(),
				closed: false,
			}),
			Condvar::new(),
		));
		let drained = Notify::new();
		assert!(await_inbound_room(&inbound, &drained, 1).await);
	}

	#[test]
	fn readiness_coalesces_bits_per_stable_peer() {
		let readiness = Readiness::new().unwrap();
		readiness.signal(7, EV_CANDIDATE);
		readiness.signal(7, EV_OPEN | EV_WRITABLE);
		readiness.signal(9, EV_READABLE);

		let mut state = readiness.state.lock().unwrap();
		assert_eq!(state.subjects.len(), 2);
		assert_eq!(state.subjects.pop_front(), Some(7));
		assert_eq!(state.events.remove(&7), Some(EV_CANDIDATE | EV_OPEN | EV_WRITABLE));
		assert_eq!(state.subjects.pop_front(), Some(9));
		assert_eq!(state.events.remove(&9), Some(EV_READABLE));
	}

	#[test]
	fn signaling_and_driver_readiness_are_independent_subscriptions() {
		let signaling = Readiness::new().unwrap();
		let shared = test_shared(
			7,
			Arc::new((
				Mutex::new(Inbound {
					buf: VecDeque::new(),
					closed: false,
				}),
				Condvar::new(),
			)),
			Arc::new(Mutex::new(OpenGate {
				open: false,
				closed: false,
			})),
			Arc::new(Notify::new()),
			signaling.clone(),
		);
		let driver = shared.endpoint.driver_readiness().unwrap();

		shared.endpoint.signal(7, EV_CANDIDATE | EV_OPEN);
		let mut event = [PancakeWebrtcReadyEvent { subject: 0, events: 0 }];
		assert_eq!(signaling.drain(&mut event), 1);
		assert_eq!(event[0].events, EV_CANDIDATE | EV_OPEN);
		assert_eq!(driver.drain(&mut event), 1);
		assert_eq!(event[0].events, EV_CANDIDATE | EV_OPEN);
	}

	#[test]
	fn a_full_self_pipe_is_already_a_readable_wakeup() {
		let readiness = Readiness::new().unwrap();
		let fill = [1u8; 4096];
		{
			let mut writer = readiness.writer.lock().unwrap();
			loop {
				match writer.write(&fill) {
					Ok(_) => {}
					Err(err) if err.kind() == std::io::ErrorKind::Interrupted => continue,
					Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => break,
					Err(err) => panic!("unexpected self-pipe fill error: {err}"),
				}
			}
		}

		// `signal` cannot add another byte, but the full pipe already wakes poll.
		readiness.signal(7, EV_READABLE);
		let mut byte = [0u8; 1];
		let mut reader = &readiness.reader;
		assert_eq!(reader.read(&mut byte).unwrap(), 1);
		assert_eq!(readiness.state.lock().unwrap().events.get(&7), Some(&EV_READABLE));
	}

	#[test]
	fn the_exported_readiness_half_cannot_be_written() {
		let readiness = Readiness::new().unwrap();
		let mut exported = &readiness.reader;
		assert!(exported.write_all(&[1]).is_err());

		readiness.signal(7, EV_OPEN);
		let mut byte = [0u8; 1];
		let mut exported = &readiness.reader;
		assert_eq!(exported.read(&mut byte).unwrap(), 1);
	}

	#[test]
	fn inbound_drain_releases_burst_capacity() {
		let mut state = Inbound {
			buf: VecDeque::with_capacity(INBOUND_BUFFER_BOUND),
			closed: false,
		};
		state.buf.extend(std::iter::repeat(7u8).take(STEADY_BUFFER_BYTES * 2));
		assert!(state.buf.capacity() > STEADY_BUFFER_BYTES);
		let mut dest = vec![0u8; state.buf.len()];
		assert_eq!(take_inbound(&mut state, &mut dest), dest.len());
		assert!(state.buf.is_empty());
		assert!(state.buf.capacity() <= STEADY_BUFFER_BYTES);
	}

	#[test]
	fn loopback_binding_is_additive() {
		assert_eq!(udp_bind_addrs(false), vec!["0.0.0.0:0".to_owned()]);
		assert_eq!(
			udp_bind_addrs(true),
			vec!["0.0.0.0:0".to_owned(), "127.0.0.1:0".to_owned()]
		);
	}

	#[test]
	fn outbound_bound_admits_a_prefix_and_retry_makes_progress() {
		let mut state = Outbound {
			buf: BytesMut::new(),
			queued_bytes: 0,
			closed: false,
		};
		let bytes = vec![9u8; OUTBOUND_BUFFER_BOUND + 17];
		assert_eq!(enqueue_outbound(&mut state, &bytes), OUTBOUND_BUFFER_BOUND as isize);
		assert_eq!(
			enqueue_outbound(&mut state, &bytes[OUTBOUND_BUFFER_BOUND..]),
			WOULD_BLOCK as isize
		);

		let sent = state.buf.split_to(STEADY_BUFFER_BYTES);
		drop(sent);
		state.queued_bytes -= STEADY_BUFFER_BYTES;
		assert_eq!(enqueue_outbound(&mut state, &bytes[OUTBOUND_BUFFER_BOUND..]), 17);
		assert!(state.queued_bytes <= OUTBOUND_BUFFER_BOUND);
	}

	#[tokio::test]
	async fn runtime_owner_can_drop_inside_an_async_context() {
		let rt = tokio::runtime::Builder::new_multi_thread()
			.worker_threads(1)
			.enable_all()
			.build()
			.unwrap();
		drop(RuntimeOwner(Some(rt)));
	}

	#[test]
	fn terminal_event_is_published_exactly_once_even_after_a_drain() {
		let inbound = Arc::new((
			Mutex::new(Inbound {
				buf: VecDeque::new(),
				closed: false,
			}),
			Condvar::new(),
		));
		let open = Arc::new(Mutex::new(OpenGate {
			open: false,
			closed: false,
		}));
		let drained = Arc::new(Notify::new());
		let readiness = Readiness::new().unwrap();
		let shared = test_shared(7, inbound.clone(), open.clone(), drained, readiness.clone());

		publish_peer_closed(&shared);
		let mut events = [PancakeWebrtcReadyEvent { subject: 0, events: 0 }];
		assert_eq!(readiness.drain(&mut events), 1);
		assert_eq!(events[0].subject, 7);
		assert_eq!(events[0].events, EV_CLOSED);

		publish_peer_closed(&shared);
		let ready = readiness.state.lock().unwrap();
		assert!(ready.subjects.is_empty());
		assert!(ready.events.is_empty());
		assert!(inbound.0.lock().unwrap().closed);
		assert!(open.lock().unwrap().closed);
		assert!(shared.outbound.lock().unwrap().closed);
	}

	/// The ICE servers a caller names reach the endpoint, and a caller that
	/// names none still gets one.
	///
	/// A live STUN server cannot be reached from a hermetic test, so what this
	/// holds is the seam rather than the traversal: the URLs are parsed, split,
	/// and carried onto the endpoint every peer is built from. Without it the
	/// setting would be a claim nothing exercises.
	#[test]
	fn ice_servers_reach_the_endpoint() {
		let urls = b"stun:stun.example:3478, stun:other.example:3478";
		let cfg = PancakeWebrtcEndpointConfig {
			ice_servers: urls.as_ptr(),
			ice_servers_len: urls.len(),
			include_loopback_candidates: 0,
			worker_threads: 0,
		};
		let ep = pancake_webrtc_sidecar_endpoint_new(&cfg);
		assert!(!ep.is_null());
		// The comma-separated list splits, and surrounding space is not part of
		// a URL.
		assert_eq!(
			unsafe { &*ep }.inner.ice_servers,
			vec![
				"stun:stun.example:3478".to_string(),
				"stun:other.example:3478".to_string()
			]
		);
		unsafe { pancake_webrtc_sidecar_endpoint_free(ep) };

		let empty = PancakeWebrtcEndpointConfig {
			ice_servers: std::ptr::null(),
			ice_servers_len: 0,
			include_loopback_candidates: 0,
			worker_threads: 0,
		};
		let host_only = pancake_webrtc_sidecar_endpoint_new(&empty);
		assert!(!host_only.is_null());
		assert!(unsafe { &*host_only }.inner.ice_servers.is_empty());
		unsafe { pancake_webrtc_sidecar_endpoint_free(host_only) };
	}

	/// A null config is refused rather than silently taken as "no ICE servers",
	/// so a caller that forgot to pass one finds out here instead of in a
	/// deployment where nothing can traverse NAT.
	#[test]
	fn a_null_config_is_refused() {
		assert!(pancake_webrtc_sidecar_endpoint_new(std::ptr::null()).is_null());
	}

	#[test]
	fn teardown_panics_become_failures() {
		assert_eq!(teardown_status(|| {}), OK);
		assert_eq!(teardown_status(|| panic!("forced teardown panic")), ERR);
	}
}
