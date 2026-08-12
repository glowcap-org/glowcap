//! The iroh netlayer sidecar (ADR-0055).
//!
//! This staticlib wraps one iroh endpoint behind the narrow C ABI
//! declared in `include/pancake_iroh_sidecar.h`, emitting
//! `libpancake_iroh_sidecar.a`. The Zig resident
//! (`src/net/transport/iroh.zig`) is the only consumer. Shape decisions:
//!
//! * Each endpoint owns its own tokio runtime behind the opaque handle, so a
//!   caller needs no async runtime of its own. Evented dial, accept, and stream
//!   I/O surface through one readiness fd; the explicit blocking resident keeps
//!   the few `_blocking` calls. The runtime's thread bill is explicit and
//!   bounded: two worker threads named `pancake-iroh`.
//! * The caller chooses the endpoint's reachability when it is created, and
//!   nothing is on by default: `REACH_DIRECT` binds relay-less and lookup-less
//!   (dial by id plus explicit address hints), `REACH_DISCOVERY` adds the
//!   number-0 relays and DNS/pkarr discovery so a peer is dialable by id alone
//!   over the public internet, `REACH_DISCOVERY_NO_RELAY` keeps discovery but
//!   drops relays, and `REACH_LOCAL_DISCOVERY` is an in-process address book for
//!   tests and same-process embeddings. Enabling relays or a discovery service
//!   is always the host's explicit decision, never a hidden default.
//! * One bidirectional QUIC stream carries the whole OCapN session. QUIC bi
//!   streams are lazy — the acceptor cannot see the stream until the dialer
//!   writes — which OCapN guarantees, because the dialer sends `op:start-session`
//!   first.
//! * No panic crosses the FFI boundary: every entry point runs under
//!   `catch_unwind` and maps a panic to the function's error return.

use std::collections::{BTreeSet, HashMap, VecDeque};
use std::io::{Read as _, Write as _};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::str::FromStr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use iroh::address_lookup::memory::MemoryLookup;
use iroh::endpoint::{presets, Connection, RecvStream, SendStream};
use iroh::{Endpoint, EndpointAddr, EndpointId, SecretKey};
use tokio::sync::Notify;
use tokio::task::JoinHandle;

/// The ALPN both pancake peers negotiate (ADR-0055).
const ALPN: &[u8] = b"ocapn/pancake/1";

/// Upper bound on a single dial, discovery resolution plus relay/hole-punch
/// setup. A dial that cannot be established within this window terminates with
/// a timed-out code (the Zig resident maps it to `error.TimedOut`). Loopback and
/// in-process dials complete in
/// milliseconds, so this bounds only the public-discovery path, where it keeps a
/// failed dial from hanging a gate or a caller.
const CONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// The connection-level idle timeout when the caller names none. What the
/// setting is for is documented once, on the C ABI's `PancakeIrohConfig`; this
/// is why the default is what it is.
///
/// iroh sends keep-alives and bounds an individual *path* at fifteen seconds,
/// but leaves the connection-level timeout to its own default, which measured
/// at about thirty-three seconds end to end. Fifteen matches the path bound
/// iroh itself chose rather than inventing a number.
const IDLE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);

/// How often iroh sends a keep-alive by default, mirrored here because the
/// heartbeat has to be chosen against the idle timeout and the two live in
/// different crates. Reading it wrong costs a keep-alive that is too slow for
/// the timeout beside it, so it is stated rather than assumed.
const IROH_HEARTBEAT: std::time::Duration = std::time::Duration::from_secs(5);

/// Maximum lifetime of an admitted non-blocking write after local close. The
/// loop-facing free remains immediate, while a peer that never restores QUIC
/// flow-control credit cannot strand a detached task and its bounded batch for
/// the endpoint's remaining lifetime.
const CLOSE_DRAIN_TIMEOUT: std::time::Duration = IDLE_TIMEOUT;

/// Worker threads for one endpoint's runtime when the caller names none. It is a
/// per-endpoint cost, so a process holding many endpoints, or one endpoint
/// holding many connections, should say what it wants instead.
const WORKER_THREADS: usize = 2;

/// One endpoint's configuration, passed by pointer rather than spread across
/// positional arguments.
///
/// Every layer above this one already carries a config object: the Zig
/// resident's `Resident.Config` and the C ABI's `PancakeIrohConfig`. This is
/// the layer that was still counting arguments, and each new endpoint knob was
/// widening a signature that four call sites and an `extern fn` declaration had
/// to agree on. A struct means the next one is a field.
///
/// Zero means "no opinion" for both timeouts, which is what a caller that fills
/// only `reachability` gets from a zeroed struct.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct PancakeIrohEndpointConfig {
	/// One of `PANCAKE_IROH_REACH_*`. Mandatory; an unknown value is refused.
	pub reachability: u32,
	/// Stream-establishment deadline in milliseconds, 0 for the default.
	pub connect_timeout_ms: u64,
	/// How long a connection survives with nothing arriving on it, in
	/// milliseconds, 0 for the default. See `IDLE_TIMEOUT`.
	pub idle_timeout_ms: u64,
	/// Worker threads for this endpoint's runtime; 0 takes `WORKER_THREADS`.
	pub worker_threads: u32,
}

/// Reachability postures, chosen explicitly by the caller, with no default. A
/// pancake peer never enables relays or a discovery service as a
/// hidden implementation detail; the host decides, in the open, how this
/// endpoint becomes reachable. These values mirror
/// `PANCAKE_IROH_REACH_*` in `include/pancake_iroh_sidecar.h` and the
/// `Reachability` enum the Zig resident exposes.
const REACH_DIRECT: u32 = 0;
const REACH_DISCOVERY: u32 = 1;
const REACH_DISCOVERY_NO_RELAY: u32 = 2;
const REACH_LOCAL_DISCOVERY: u32 = 3;

/// `conn_try_read` / `conn_try_write` return this when the operation cannot make
/// progress without blocking: no inbound bytes are buffered yet, or the outbound
/// buffer has no room. The loop yields the connection and re-arms it on the next
/// readiness event. Distinct from `0` (clean end of stream or zero-length write)
/// and `-1` (error). Mirrors `PANCAKE_IROH_WOULD_BLOCK` in the header and the
/// Zig resident.
const WOULD_BLOCK: isize = -2;

/// Readiness event bits packed into `PancakeIrohReadyEvent.events`. A single
/// drained record may carry several at once (e.g. `EV_READABLE | EV_CLOSED` when
/// the peer's last bytes arrive with its end of stream).
const EV_READABLE: u32 = 1;
const EV_WRITABLE: u32 = 2;
const EV_CLOSED: u32 = 4;
const EV_ACCEPT: u32 = 8;
const EV_CONNECT: u32 = 16;

const DIAL_OK: i32 = 0;
const DIAL_INVALID: i32 = 1;
const DIAL_TIMEOUT: i32 = 2;
const DIAL_UNREACHABLE: i32 = 3;
const DIAL_LOST: i32 = 4;
const DIAL_CANCELED: i32 = 5;
const DIAL_PENDING: i32 = 6;
const DIAL_BUSY: i32 = 7;

/// The non-blocking inbound/outbound buffer bound, per connection and direction
/// (ADR-0057's back-pressure policy). A reader that fills the inbound buffer
/// stops reading the QUIC stream until the loop drains it, so a slow consumer
/// applies QUIC flow control to its partner rather than letting the sidecar
/// buffer without limit; a `conn_try_write` admits only the prefix that fits
/// under the outbound bound and returns `WOULD_BLOCK` only when no byte can fit.
/// One largest-admissible CapTP frame fits well within this, so steady traffic
/// never blocks on it.
const NB_BUFFER_BOUND: usize = 1 << 20;

/// The steady per-direction buffer capacity a connection retains once a burst
/// drains, mirroring the Zig posture (`default_read_buffer_bytes` in
/// `src/net/completion/loop.zig` and `steady_outbound_bytes` in
/// `src/net/frame_stream.zig`, both 16 KiB):
/// burst capacity frees on drain so one slow episode never pins its high-water
/// bytes for the connection's lifetime, while steady-sized capacity is retained
/// so ordinary traffic never reallocates.
const NB_STEADY_BYTES: usize = 16 * 1024;

/// Cap on one `read_chunk` segment in the reader task. The chunk is a zero-copy
/// borrow of the QUIC reassembly buffer, so the cap costs no memory. The reader
/// further limits every request to the queue's exact remaining budget, keeping
/// `NB_BUFFER_BOUND` an actual bound rather than a threshold with overshoot.
const READ_CHUNK_BYTES: usize = 64 * 1024;

/// Accepted loop connections retained by the sidecar before Zig claims them.
/// This mirrors `src/net/transport/iroh.zig`'s accept stash: both producer and
/// consumer queues have the same admission posture.
const ACCEPT_QUEUE_BOUND: usize = 128;

/// Outbound dials retained as Tokio tasks or terminal results until the caller
/// consumes them. A caller controls request ids and completion consumption, so
/// this boundary must refuse admission rather than turn either behavior into an
/// unbounded endpoint-owned task/map queue.
const DIAL_ADMISSION_BOUND: usize = 32;

/// One drained readiness record. `subject` is zero for `EV_ACCEPT`, a caller
/// request id for `EV_CONNECT`, and otherwise a stable endpoint-scoped
/// connection id. `#[repr(C)]` keeps the layout in lockstep with
/// `pancake_iroh_sidecar_ready_event` and the Zig resident's `ReadyEvent`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct PancakeIrohReadyEvent {
	subject: usize,
	events: u32,
}

/// The process-shared address book backing `REACH_LOCAL_DISCOVERY`. Every
/// endpoint bound in that mode publishes its own `EndpointAddr` here and
/// resolves partners from it, so a dial by endpoint id alone — no relay, no
/// DNS, no caller-supplied address hints — succeeds inside one process. This is
/// the deterministic, infrastructure-free discovery path: it carries the
/// `iroh-interop` proof and serves same-process embeddings, never the public
/// internet (that is `REACH_DISCOVERY`).
static LOCAL_BOOK: OnceLock<MemoryLookup> = OnceLock::new();

fn local_book() -> &'static MemoryLookup {
	LOCAL_BOOK.get_or_init(MemoryLookup::new)
}

/// The endpoint's directly dialable socket addresses, with wildcard bindings
/// reported in their loopback form so the set is dialable on the local host.
fn dialable_addrs(ep: &Endpoint) -> BTreeSet<SocketAddr> {
	let mut addrs: BTreeSet<SocketAddr> = BTreeSet::new();
	for addr in ep.bound_sockets() {
		let dialable = match addr.ip() {
			IpAddr::V4(ip) if ip.is_unspecified() => {
				SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), addr.port())
			}
			IpAddr::V6(ip) if ip.is_unspecified() => {
				SocketAddr::new(IpAddr::V6(Ipv6Addr::LOCALHOST), addr.port())
			}
			_ => addr,
		};
		addrs.insert(dialable);
	}
	for addr in ep.addr().ip_addrs() {
		addrs.insert(*addr);
	}
	addrs
}

/// Publish this endpoint's id and direct addresses into the process-shared
/// address book so a `REACH_LOCAL_DISCOVERY` partner can dial it by id alone.
fn publish_local(ep: &Endpoint) {
	let mut addr = EndpointAddr::new(ep.id());
	for sock in dialable_addrs(ep) {
		addr = addr.with_ip_addr(sock);
	}
	local_book().add_endpoint_info(addr);
}

/// Opaque endpoint handle: the iroh endpoint plus the tokio runtime it runs on.
/// `readiness` and `accept` are lazily created the first time the event-driven
/// scale surface (ADR-0057) is used on this endpoint; an endpoint driven only
/// through the blocking calls never allocates them.
pub struct PancakeIrohEndpoint {
	rt: tokio::runtime::Runtime,
	ep: Endpoint,
	/// The deadline every bi-stream establishment on this endpoint rides — the
	/// dial's `connect` + `open_bi` and each `accept_bi` — so a partner that
	/// stalls mid-handshake cannot park a thread forever. Configured per
	/// endpoint (`connect_timeout_ms`, 0 = the `CONNECT_TIMEOUT` default).
	connect_timeout: std::time::Duration,
	readiness: OnceLock<Arc<Readiness>>,
	accept: OnceLock<Arc<AcceptState>>,
	dials: OnceLock<Arc<DialState>>,
	/// Terminal ownership for non-blocking writers. Completed tasks retain no
	/// endpoint row; release waits only on the active count.
	writers: Arc<WriterTasks>,
	next_conn_id: AtomicUsize,
}

struct WriterTasks {
	active: AtomicUsize,
	drained: Notify,
}

impl WriterTasks {
	fn new() -> Self {
		Self {
			active: AtomicUsize::new(0),
			drained: Notify::new(),
		}
	}

	fn acquire(self: &Arc<Self>) -> WriterPermit {
		self.active.fetch_add(1, Ordering::Relaxed);
		WriterPermit(self.clone())
	}

	async fn wait(&self) {
		loop {
			let drained = self.drained.notified();
			if self.active.load(Ordering::Acquire) == 0 {
				return;
			}
			drained.await;
		}
	}
}

struct WriterPermit(Arc<WriterTasks>);

impl Drop for WriterPermit {
	fn drop(&mut self) {
		if self.0.active.fetch_sub(1, Ordering::AcqRel) == 1 {
			self.0.drained.notify_waiters();
		}
	}
}

/// Opaque connection handle: one QUIC connection carrying one bidirectional
/// stream. `send` and `recv` are independently locked so the two directions
/// never serialize against each other; they are `Option` because
/// `conn_set_nonblocking` moves the streams out to the reader/writer tasks,
/// after which the blocking calls refuse (the connection is owned by the loop).
/// `nb` holds the non-blocking state once that transition happens.
pub struct PancakeIrohConn {
	id: usize,
	rt: tokio::runtime::Handle,
	conn: Connection,
	send: Mutex<Option<SendStream>>,
	recv: Mutex<Option<RecvStream>>,
	/// Serializes the one ownership transition that takes both streams. The
	/// steady read/write path still locks each direction independently.
	nonblocking_transition: Mutex<()>,
	nb: OnceLock<Arc<NbConn>>,
	/// The reader/writer task handles. `conn_free` aborts the reader and detaches
	/// the writer without joining: each task owns only its streams, `Arc<NbConn>`,
	/// and one endpoint writer permit. Connection release stays non-blocking while
	/// the permit gives endpoint release its terminal drain barrier.
	nb_tasks: OnceLock<(JoinHandle<()>, JoinHandle<()>)>,
	/// Endpoint-scoped terminal owner for a writer detached at conn release.
	writers: Arc<WriterTasks>,
}

/// One endpoint's readiness channel: the self-pipe the loop polls plus the queue
/// of pending `(subject, events)` records. Every readiness signal appends to
/// `queue` and writes one byte to `writer`, so a loop blocked on the read end
/// wakes and drains the queue.
struct Readiness {
	/// The read end the loop polls; `endpoint_readiness_fd` returns its fd.
	reader: UnixStream,
	/// The write end, set non-blocking so a coalesced wakeup never parks a task;
	/// the queue, not the byte count, is the source of truth.
	writer: Mutex<UnixStream>,
	queue: Mutex<ReadyQueue>,
}

struct ReadyQueue {
	order: VecDeque<usize>,
	events: HashMap<usize, u32>,
}

impl ReadyQueue {
	fn new() -> ReadyQueue {
		ReadyQueue {
			order: VecDeque::new(),
			events: HashMap::new(),
		}
	}

	fn len(&self) -> usize {
		self.order.len()
	}

	fn is_empty(&self) -> bool {
		self.order.is_empty()
	}

	fn push_or_coalesce(&mut self, subject: usize, events: u32) {
		if let Some(existing) = self.events.get_mut(&subject) {
			*existing |= events;
			return;
		}
		self.order.push_back(subject);
		self.events.insert(subject, events);
	}

	fn pop_front(&mut self) -> Option<PancakeIrohReadyEvent> {
		let subject = self.order.pop_front()?;
		let events = self.events.remove(&subject)?;
		Some(PancakeIrohReadyEvent { subject, events })
	}
}

impl Readiness {
	fn new() -> Option<Arc<Readiness>> {
		let (reader, writer) = UnixStream::pair().ok()?;
		// Both ends non-blocking: the loop drains the read end without parking,
		// and a coalesced wakeup never blocks a signalling task on a full pipe.
		reader.set_nonblocking(true).ok()?;
		writer.set_nonblocking(true).ok()?;
		reader.shutdown(std::net::Shutdown::Write).ok()?;
		Some(Arc::new(Readiness {
			reader,
			writer: Mutex::new(writer),
			queue: Mutex::new(ReadyQueue::new()),
		}))
	}

	/// Best-effort self-pipe wake used both when publishing an event and when a
	/// short drain leaves queued records. `WouldBlock` is safe to discard because
	/// it means unread bytes fill the pipe, so the read fd is already poll-readable.
	/// Interrupted writes retry because they provide no such guarantee.
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

	/// Enqueue one readiness record and nudge the self-pipe.
	fn signal(&self, subject: usize, events: u32) {
		{
			let mut queue = self.queue.lock().unwrap();
			queue.push_or_coalesce(subject, events);
		}
		self.nudge();
	}

	/// Clear coalesced wake bytes before draining authoritative records. A signal
	/// racing this operation either joins this drain or leaves a byte for the next
	/// poll. A short record drain re-nudges the fd for its remaining backlog.
	fn drain(&self, dest: &mut [PancakeIrohReadyEvent]) -> usize {
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

		let mut queue = self.queue.lock().unwrap();
		let count = dest.len().min(queue.len());
		for slot in dest.iter_mut().take(count) {
			*slot = queue.pop_front().unwrap();
		}
		let remaining = !queue.is_empty();
		drop(queue);
		if remaining {
			self.nudge();
		}
		count
	}
}

/// The acceptor side of an endpoint's scale surface: connections the acceptor
/// task has pulled off the wire, waiting for `endpoint_try_accept` to claim
/// them. Built (and the task spawned) by `endpoint_set_nonblocking_accept`.
struct AcceptState {
	ready: Mutex<VecDeque<AcceptedRaw>>,
}

/// One accepted connection the acceptor task produced but the loop has not yet
/// claimed: the QUIC connection and its first bidirectional stream, carried by
/// value (every part is `Send`) so the task never holds a raw handle pointer.
struct AcceptedRaw {
	conn: Connection,
	send: SendStream,
	recv: RecvStream,
}

/// One endpoint's in-flight and completed outbound dials. A request id exists
/// in exactly one state until `finish_connect` consumes it. The endpoint owns a
/// successful raw connection until that transfer.
struct DialState {
	entries: Mutex<HashMap<usize, DialEntry>>,
	readiness: Arc<Readiness>,
}

enum DialEntry {
	Pending {
		abort: Option<tokio::task::AbortHandle>,
	},
	Terminal(Result<AcceptedRaw, i32>),
}

impl DialState {
	fn complete(&self, request_id: usize, result: Result<AcceptedRaw, i32>) {
		let publish = {
			let mut entries = self.entries.lock().unwrap();
			match entries.get_mut(&request_id) {
				Some(entry @ DialEntry::Pending { .. }) => {
					*entry = DialEntry::Terminal(result);
					true
				}
				Some(DialEntry::Terminal(_)) | None => false,
			}
		};
		if publish {
			self.readiness.signal(request_id, EV_CONNECT);
		}
	}

	fn cancel(&self, request_id: usize) -> bool {
		let (found, publish, abort) = {
			let mut entries = self.entries.lock().unwrap();
			match entries.get_mut(&request_id) {
				Some(entry @ DialEntry::Pending { .. }) => {
					let abort = match entry {
						DialEntry::Pending { abort } => abort.take(),
						DialEntry::Terminal(_) => unreachable!(),
					};
					*entry = DialEntry::Terminal(Err(DIAL_CANCELED));
					(true, true, abort)
				}
				Some(DialEntry::Terminal(_)) => (true, false, None),
				None => (false, false, None),
			}
		};
		if let Some(abort) = abort {
			abort.abort();
		}
		if publish {
			self.readiness.signal(request_id, EV_CONNECT);
		}
		found
	}

	fn cancel_all(&self) {
		let mut signals = Vec::new();
		let mut aborts = Vec::new();
		{
			let mut entries = self.entries.lock().unwrap();
			for (request_id, entry) in entries.iter_mut() {
				if let DialEntry::Pending { abort } = entry {
					if let Some(abort) = abort.take() {
						aborts.push(abort);
					}
					*entry = DialEntry::Terminal(Err(DIAL_CANCELED));
					signals.push(*request_id);
				}
			}
		}
		for abort in aborts {
			abort.abort();
		}
		for request_id in signals {
			self.readiness.signal(request_id, EV_CONNECT);
		}
	}
}

/// Non-blocking state for one connection: the bounded inbound/outbound buffers
/// the reader and writer tasks move bytes through, the notifies that wake those
/// tasks, and the endpoint readiness this connection signals into. The reader
/// and writer tasks own the QUIC streams (moved out of `PancakeIrohConn`), so
/// they can hold them across `.await` without a `!Send` guard.
struct NbConn {
	readiness: Arc<Readiness>,
	/// Stable endpoint-scoped identity the loop matches drained records against.
	id: usize,
	inbound: Mutex<Inbound>,
	outbound: Mutex<Outbound>,
	/// Woken when the loop drains the inbound buffer: the reader parks here when
	/// the inbound buffer is at its bound and resumes when room frees.
	read_room: Notify,
	/// Woken when the loop enqueues outbound bytes or closes the connection: the
	/// writer parks here when the outbound buffer is empty.
	write_work: Notify,
	/// Wakes a writer already suspended inside QUIC flow control so its graceful
	/// drain acquires a deadline without making `conn_free` wait.
	close_work: Notify,
}

/// The inbound bytes as the Zig side treats them: one contiguous buffer with a
/// consumed prefix, `buf[off..]` unread. The reader appends whole QUIC chunks
/// with a memcpy; `conn_try_read` drains by advancing `off`. Draining to empty
/// resets the buffer and frees burst capacity past `NB_STEADY_BYTES`; a partial
/// drain compacts once the consumed prefix reaches the pending bytes, so the
/// buffer tracks the bounded pending count, never the total bytes ever
/// received.
#[derive(Default)]
struct Inbound {
	buf: Vec<u8>,
	/// Length of the consumed prefix of `buf`; `buf.len() - off` bytes pend.
	off: usize,
	/// Set once the QUIC recv stream reaches clean end of stream.
	eof: bool,
	/// Set once the reader task hit a transport error.
	err: bool,
}

impl Inbound {
	fn pending(&self) -> usize {
		self.buf.len() - self.off
	}

	fn read_budget(&self) -> usize {
		NB_BUFFER_BOUND
			.saturating_sub(self.pending())
			.min(READ_CHUNK_BYTES)
	}
}

#[derive(Default)]
struct Outbound {
	/// Bytes queued behind the writer's current batch.
	buf: Vec<u8>,
	/// Cleared allocation returned by the writer for the next batch. Keeping one
	/// steady-sized spare removes allocation churn without retaining a burst.
	spare: Vec<u8>,
	/// Bytes currently borrowed by the QUIC write future. Queue admission counts
	/// these too, so staging plus in-flight work share one `NB_BUFFER_BOUND`.
	in_flight: usize,
	/// Set by `conn_close` / `conn_free`: the writer finishes the send stream
	/// and exits once the buffer drains.
	closed: bool,
}

impl Outbound {
	fn pending(&self) -> usize {
		self.buf.len() + self.in_flight
	}

	fn take_batch(&mut self) -> Vec<u8> {
		debug_assert_eq!(self.in_flight, 0);
		let mut batch = std::mem::take(&mut self.spare);
		std::mem::swap(&mut batch, &mut self.buf);
		self.in_flight = batch.len();
		batch
	}

	fn finish_batch(&mut self, mut batch: Vec<u8>, succeeded: bool) {
		debug_assert_eq!(self.in_flight, batch.len());
		self.in_flight = 0;
		if !succeeded {
			self.closed = true;
		}
		batch.clear();
		if batch.capacity() > NB_STEADY_BYTES {
			batch.shrink_to(NB_STEADY_BYTES);
		}
		self.spare = batch;
	}
}

fn enqueue_outbound(out: &mut Outbound, src: &[u8]) -> isize {
	if out.closed {
		return -1;
	}
	if src.is_empty() {
		return 0;
	}
	let room = NB_BUFFER_BOUND.saturating_sub(out.pending());
	if room == 0 {
		return WOULD_BLOCK;
	}
	let accepted = room.min(src.len());
	out.buf.extend_from_slice(&src[..accepted]);
	accepted as isize
}

/// Create an endpoint. `secret_seed32` is either null (generate a fresh random
/// endpoint key) or a pointer to 32 bytes of Ed25519 secret key material.
/// `reachability` selects how this endpoint becomes reachable and is mandatory,
/// one of `PANCAKE_IROH_REACH_*`, with no implicit default. An unknown value
/// returns null. Returns an owned handle (release with
/// `pancake_iroh_sidecar_endpoint_free`) or null on failure. Blocks until the
/// UDP sockets are bound.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_endpoint_new(
	secret_seed32: *const u8,
	config: *const PancakeIrohEndpointConfig,
) -> *mut PancakeIrohEndpoint {
	if config.is_null() {
		return std::ptr::null_mut();
	}
	// Safety: the contract requires a readable config when non-null.
	let PancakeIrohEndpointConfig {
		reachability,
		connect_timeout_ms,
		idle_timeout_ms,
		worker_threads,
	} = unsafe { *config };
	let result = catch_unwind(AssertUnwindSafe(|| {
		let rt = tokio::runtime::Builder::new_multi_thread()
			.worker_threads(if worker_threads == 0 {
				WORKER_THREADS
			} else {
				worker_threads as usize
			})
			.thread_name("pancake-iroh")
			.enable_all()
			.build()
			.ok()?;
		// The reachability posture is the whole choice here: `Minimal` binds
		// relay-less and lookup-less, `N0` adds the number-0 relays and DNS/pkarr
		// discovery, `N0DisableRelay` keeps discovery but drops relays, and the
		// local book is an in-process address exchange. The caller picked one.
		let mut builder = match reachability {
			REACH_DIRECT => Endpoint::builder(presets::Minimal),
			REACH_DISCOVERY => Endpoint::builder(presets::N0),
			REACH_DISCOVERY_NO_RELAY => Endpoint::builder(presets::N0DisableRelay),
			REACH_LOCAL_DISCOVERY => {
				Endpoint::builder(presets::Minimal).address_lookup(local_book().clone())
			}
			_ => return None,
		};
		builder = builder.alpns(vec![ALPN.to_vec()]);
		// The connection-level idle timeout, which nothing else sets: iroh's own
		// defaults cover keep-alives and the per-path bound, and leave this one
		// to the QUIC stack. It is what decides how long a peer that vanished
		// keeps its place. 0 is the caller declining to choose.
		let idle = if idle_timeout_ms == 0 {
			IDLE_TIMEOUT
		} else {
			std::time::Duration::from_millis(idle_timeout_ms)
		};
		if let Ok(timeout) = iroh::endpoint::IdleTimeout::try_from(idle) {
			// Keep-alives are not a second knob, because the two are one
			// decision. An idle timeout is only honest if packets are still
			// expected to arrive on a connection nobody is using, and that is
			// what a keep-alive provides. Exposing both would let a caller set
			// a timeout shorter than its own heartbeat and drop connections
			// whose peers are alive and answering.
			//
			// So the caller states the one thing it means — how fast a dead
			// peer should be noticed — and the heartbeat follows it: iroh's
			// five-second default, or a third of the timeout when the caller
			// asked for something tighter. A third leaves two heartbeats free
			// to go missing before a live connection is wrongly declared dead.
			let heartbeat = std::cmp::min(IROH_HEARTBEAT, idle / 3);
			builder = builder.transport_config(
				iroh::endpoint::QuicTransportConfig::builder()
					.max_idle_timeout(Some(timeout))
					.keep_alive_interval(heartbeat)
					.build(),
			);
		}
		if !secret_seed32.is_null() {
			let mut seed = [0u8; 32];
			// Safety: the contract requires 32 readable bytes when non-null.
			seed.copy_from_slice(unsafe { std::slice::from_raw_parts(secret_seed32, 32) });
			builder = builder.secret_key(SecretKey::from(seed));
		}
		let ep = rt.block_on(builder.bind()).ok()?;
		if reachability == REACH_LOCAL_DISCOVERY {
			publish_local(&ep);
		}
		// 0 keeps the built-in default; any other value is the caller's
		// per-endpoint stream-establishment deadline in milliseconds.
		let connect_timeout = if connect_timeout_ms == 0 {
			CONNECT_TIMEOUT
		} else {
			std::time::Duration::from_millis(connect_timeout_ms)
		};
		Some(Box::into_raw(Box::new(PancakeIrohEndpoint {
			rt,
			ep,
			connect_timeout,
			readiness: OnceLock::new(),
			accept: OnceLock::new(),
			dials: OnceLock::new(),
			writers: Arc::new(WriterTasks::new()),
			next_conn_id: AtomicUsize::new(1),
		})))
	}));
	match result {
		Ok(Some(handle)) => handle,
		_ => std::ptr::null_mut(),
	}
}

/// Return a UTF-8 string's complete byte count, copying it only when the
/// caller's buffer can hold the whole value. A zero-capacity call is a query.
fn write_str(s: &str, out: *mut u8, out_cap: usize) -> isize {
	let bytes = s.as_bytes();
	if bytes.len() <= out_cap {
		// Safety: the contract requires `out_cap` writable bytes at `out`.
		unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, bytes.len()) };
	}
	bytes.len() as isize
}

/// Write the endpoint's id — its Ed25519 public key, the dialable designator —
/// into `out` as lowercase hex (64 bytes; iroh's canonical string form, which
/// its parser accepts alongside base32). Returns the complete byte count and
/// copies only when `out_cap` is large enough. Borrows the handle; writes no
/// terminator.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_endpoint_node_id(
	ep: *const PancakeIrohEndpoint,
	out: *mut u8,
	out_cap: usize,
) -> isize {
	let result = catch_unwind(AssertUnwindSafe(|| {
		let ep = unsafe { &*ep };
		write_str(&ep.ep.id().to_string(), out, out_cap)
	}));
	result.unwrap_or(-1)
}

/// Write the endpoint's directly dialable socket addresses into `out` as a
/// comma-separated UTF-8 list (e.g. `127.0.0.1:5000,[::1]:5001`). Bound
/// wildcard addresses are reported as their loopback form, so the list is
/// dialable on the local host; concretely discovered addresses are included
/// as-is. This is the hint string a partner passes to either connect surface.
/// Returns the complete byte count and copies only when `out_cap` is large
/// enough. Borrows the handle; writes no terminator.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_endpoint_direct_addrs(
	ep: *const PancakeIrohEndpoint,
	out: *mut u8,
	out_cap: usize,
) -> isize {
	let result = catch_unwind(AssertUnwindSafe(|| {
		let ep = unsafe { &*ep };
		let joined = dialable_addrs(&ep.ep)
			.iter()
			.map(|a| a.to_string())
			.collect::<Vec<_>>()
			.join(",");
		write_str(&joined, out, out_cap)
	}));
	result.unwrap_or(-1)
}

/// Parse the borrowed public target representation into an owned iroh address.
fn parse_target(
	node_id: *const u8,
	node_id_len: usize,
	addr_hints: *const u8,
	addr_hints_len: usize,
) -> Result<EndpointAddr, i32> {
	if node_id.is_null() || (addr_hints.is_null() && addr_hints_len != 0) {
		return Err(DIAL_INVALID);
	}
	let id_str = std::str::from_utf8(unsafe { std::slice::from_raw_parts(node_id, node_id_len) })
		.map_err(|_| DIAL_INVALID)?;
	let id = EndpointId::from_str(id_str).map_err(|_| DIAL_INVALID)?;
	let mut addr = EndpointAddr::new(id);
	if addr_hints_len > 0 {
		let hints =
			std::str::from_utf8(unsafe { std::slice::from_raw_parts(addr_hints, addr_hints_len) })
				.map_err(|_| DIAL_INVALID)?;
		for hint in hints.split(',') {
			let hint = hint.trim();
			if hint.is_empty() {
				continue;
			}
			let sock = SocketAddr::from_str(hint).map_err(|_| DIAL_INVALID)?;
			addr = addr.with_ip_addr(sock);
		}
	}
	Ok(addr)
}

async fn dial_raw(
	ep: Endpoint,
	addr: EndpointAddr,
	connect_timeout: std::time::Duration,
) -> Result<AcceptedRaw, i32> {
	let conn = match tokio::time::timeout(connect_timeout, ep.connect(addr, ALPN)).await {
		Ok(Ok(conn)) => conn,
		Ok(Err(e)) => {
			eprintln!("pancake-iroh: connect failed: {e:?}");
			return Err(DIAL_UNREACHABLE);
		}
		Err(_) => {
			eprintln!("pancake-iroh: connect timed out after {connect_timeout:?}");
			return Err(DIAL_TIMEOUT);
		}
	};
	let (send, recv) = match tokio::time::timeout(connect_timeout, conn.open_bi()).await {
		Ok(Ok(streams)) => streams,
		Ok(Err(e)) => {
			eprintln!("pancake-iroh: open_bi failed: {e:?}");
			return Err(DIAL_LOST);
		}
		Err(_) => {
			eprintln!("pancake-iroh: open_bi timed out after {connect_timeout:?}");
			return Err(DIAL_TIMEOUT);
		}
	};
	Ok(AcceptedRaw { conn, send, recv })
}

fn make_conn(ep: &PancakeIrohEndpoint, raw: AcceptedRaw) -> Option<*mut PancakeIrohConn> {
	let id = ep
		.next_conn_id
		.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |next| {
			next.checked_add(1)
		})
		.ok()?;
	Some(Box::into_raw(Box::new(PancakeIrohConn {
		id,
		rt: ep.rt.handle().clone(),
		conn: raw.conn,
		send: Mutex::new(Some(raw.send)),
		recv: Mutex::new(Some(raw.recv)),
		nonblocking_transition: Mutex::new(()),
		nb: OnceLock::new(),
		nb_tasks: OnceLock::new(),
		writers: ep.writers.clone(),
	})))
}

fn endpoint_dials(ep: &PancakeIrohEndpoint) -> Option<&Arc<DialState>> {
	if ep.dials.get().is_none() {
		let readiness = endpoint_readiness(ep)?.clone();
		let _ = ep.dials.set(Arc::new(DialState {
			entries: Mutex::new(HashMap::new()),
			readiness,
		}));
	}
	ep.dials.get()
}

/// Deliberately blocking convenience for the explicit blocking resident. The
/// evented backend and public ABI use start/finish/cancel below.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_connect_blocking(
	ep: *mut PancakeIrohEndpoint,
	node_id: *const u8,
	node_id_len: usize,
	addr_hints: *const u8,
	addr_hints_len: usize,
	out_code: *mut i32,
) -> *mut PancakeIrohConn {
	let result = catch_unwind(AssertUnwindSafe(|| -> Result<*mut PancakeIrohConn, i32> {
		if ep.is_null() {
			return Err(DIAL_INVALID);
		}
		let ep = unsafe { &*ep };
		let addr = parse_target(node_id, node_id_len, addr_hints, addr_hints_len)?;
		let raw = ep
			.rt
			.block_on(dial_raw(ep.ep.clone(), addr, ep.connect_timeout))?;
		make_conn(ep, raw).ok_or(DIAL_LOST)
	}));
	let (handle, code) = match result {
		Ok(Ok(handle)) => (handle, DIAL_OK),
		Ok(Err(code)) => (std::ptr::null_mut(), code),
		Err(_) => (std::ptr::null_mut(), DIAL_LOST),
	};
	if !out_code.is_null() {
		unsafe { *out_code = code };
	}
	handle
}

/// Admit one outbound dial without blocking. Borrowed target bytes are parsed
/// before return; the endpoint owns the Tokio task and terminal result. The
/// bounded request table returns `DIAL_BUSY` without minting an event when full.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_endpoint_start_connect(
	ep: *mut PancakeIrohEndpoint,
	request_id: usize,
	node_id: *const u8,
	node_id_len: usize,
	addr_hints: *const u8,
	addr_hints_len: usize,
) -> i32 {
	let result = catch_unwind(AssertUnwindSafe(|| -> Result<(), i32> {
		if ep.is_null() || request_id == 0 {
			return Err(DIAL_INVALID);
		}
		let ep = unsafe { &*ep };
		let addr = parse_target(node_id, node_id_len, addr_hints, addr_hints_len)?;
		let dials = endpoint_dials(ep).ok_or(DIAL_LOST)?.clone();
		{
			let mut entries = dials.entries.lock().unwrap();
			if entries.contains_key(&request_id) {
				return Err(DIAL_INVALID);
			}
			if entries.len() >= DIAL_ADMISSION_BOUND {
				return Err(DIAL_BUSY);
			}
			entries.insert(request_id, DialEntry::Pending { abort: None });
		}
		let task_dials = dials.clone();
		let endpoint = ep.ep.clone();
		let timeout = ep.connect_timeout;
		let task = ep.rt.spawn(async move {
			let result = dial_raw(endpoint, addr, timeout).await;
			task_dials.complete(request_id, result);
		});
		let abort = task.abort_handle();
		drop(task);
		let should_abort = {
			let mut entries = dials.entries.lock().unwrap();
			match entries.get_mut(&request_id) {
				Some(DialEntry::Pending { abort: slot }) => {
					*slot = Some(abort.clone());
					false
				}
				Some(DialEntry::Terminal(_)) | None => true,
			}
		};
		if should_abort {
			abort.abort();
		}
		Ok(())
	}));
	match result {
		Ok(Ok(())) => DIAL_OK,
		Ok(Err(code)) => code,
		Err(_) => DIAL_LOST,
	}
}

/// Consume one terminal dial result. Returns the dial classification and writes
/// the owned connection on success. A pending request returns DIAL_PENDING.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_endpoint_finish_connect(
	ep: *mut PancakeIrohEndpoint,
	request_id: usize,
	out_conn: *mut *mut PancakeIrohConn,
) -> i32 {
	let result = catch_unwind(AssertUnwindSafe(|| {
		if ep.is_null() || out_conn.is_null() {
			return DIAL_INVALID;
		}
		unsafe { *out_conn = std::ptr::null_mut() };
		let ep = unsafe { &*ep };
		let Some(dials) = ep.dials.get() else {
			return DIAL_INVALID;
		};
		let terminal = {
			let mut entries = dials.entries.lock().unwrap();
			match entries.remove(&request_id) {
				Some(DialEntry::Terminal(result)) => result,
				Some(pending @ DialEntry::Pending { .. }) => {
					entries.insert(request_id, pending);
					return DIAL_PENDING;
				}
				None => return DIAL_INVALID,
			}
		};
		match terminal {
			Ok(raw) => {
				if let Some(conn) = make_conn(ep, raw) {
					unsafe { *out_conn = conn };
					DIAL_OK
				} else {
					DIAL_LOST
				}
			}
			Err(code) => code,
		}
	}));
	result.unwrap_or(DIAL_LOST)
}

/// Cancel one admitted dial. The pending-to-canceled winner emits the request's
/// sole terminal event; canceling an already-terminal request is idempotent.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_endpoint_cancel_connect(
	ep: *mut PancakeIrohEndpoint,
	request_id: usize,
) -> i32 {
	let result = catch_unwind(AssertUnwindSafe(|| {
		if ep.is_null() || request_id == 0 {
			return DIAL_INVALID;
		}
		let ep = unsafe { &*ep };
		match ep.dials.get() {
			Some(dials) if dials.cancel(request_id) => DIAL_OK,
			_ => DIAL_INVALID,
		}
	}));
	result.unwrap_or(DIAL_LOST)
}

async fn accept_one(ep: &PancakeIrohEndpoint) -> Option<AcceptedRaw> {
	loop {
		let incoming = ep.ep.accept().await?;
		let Ok(accepting) = incoming.accept() else {
			// Unsolicited or malformed datagrams are routine; keep accepting.
			continue;
		};
		let Ok(conn) = accepting.await else {
			continue;
		};
		// Bound the stream accept: a dialer that opens the QUIC connection but
		// never its bidirectional stream is dropped instead of holding the
		// acceptor. A stalled or failed accept keeps serving the next incoming.
		let Ok(Ok((send, recv))) = tokio::time::timeout(ep.connect_timeout, conn.accept_bi()).await
		else {
			continue;
		};
		return Some(AcceptedRaw { conn, send, recv });
	}
}

/// Wait at most `timeout_ms` for a partner connection and first bidirectional
/// stream, returning an owned connection handle or null on timeout, failure, or
/// endpoint close. A negative timeout is invalid and returns null. This is the
/// resident listener's private bounded primitive; it never arms or drains the
/// endpoint readiness queue.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_accept_timeout(
	ep: *mut PancakeIrohEndpoint,
	timeout_ms: i32,
) -> *mut PancakeIrohConn {
	if ep.is_null() || timeout_ms < 0 {
		return std::ptr::null_mut();
	}
	let result = catch_unwind(AssertUnwindSafe(|| {
		let ep = unsafe { &*ep };
		ep.rt.block_on(async {
			tokio::time::timeout(
				std::time::Duration::from_millis(timeout_ms as u64),
				accept_one(ep),
			)
			.await
			.ok()
			.flatten()
			.and_then(|raw| make_conn(ep, raw))
		})
	}));
	match result {
		Ok(Some(handle)) => handle,
		_ => std::ptr::null_mut(),
	}
}

/// Write the connection's QUIC-authenticated remote endpoint id — the 32-byte
/// Ed25519 public key TLS verified during the handshake — into `out_key32`.
/// This is the transport-layer peer proof the driver installs as pre-feed
/// CapTP hello policy on accept paths (ADR-0097); a dial already carries the
/// same guarantee, since iroh refuses to connect to any endpoint but the id
/// it was asked for. Returns 0 on success, -1 on failure. Borrows the handle.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_conn_remote_node_id(
	conn: *const PancakeIrohConn,
	out_key32: *mut u8,
) -> i32 {
	let result = catch_unwind(AssertUnwindSafe(|| {
		let conn = unsafe { &*conn };
		*conn.conn.remote_id().as_bytes()
	}));
	match result {
		Ok(bytes) => {
			unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out_key32, 32) };
			0
		}
		Err(_) => -1,
	}
}

/// Read up to `len` bytes from the stream into `buf`, blocking until at least
/// one byte arrives. Returns the byte count (> 0), 0 at clean end of stream
/// (the partner finished its send side or closed the connection cleanly), or
/// -1 on error. Borrows the handle.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_conn_read(
	conn: *mut PancakeIrohConn,
	buf: *mut u8,
	len: usize,
) -> isize {
	let result = catch_unwind(AssertUnwindSafe(|| {
		let conn = unsafe { &*conn };
		let dest = unsafe { std::slice::from_raw_parts_mut(buf, len) };
		let mut guard = match conn.recv.lock() {
			Ok(guard) => guard,
			Err(_) => return -1,
		};
		// The stream was moved into the reader task by `conn_set_nonblocking`;
		// the blocking read is no longer this caller's to make.
		let recv = match guard.as_mut() {
			Some(recv) => recv,
			None => return -1,
		};
		use iroh::endpoint::{ConnectionError, ReadError};
		match conn.rt.block_on(recv.read(dest)) {
			Ok(Some(n)) => n as isize,
			Ok(None) => 0,
			// A clean connection-level close is end-of-stream, not a fault.
			Err(ReadError::ConnectionLost(ConnectionError::ApplicationClosed(_)))
			| Err(ReadError::ConnectionLost(ConnectionError::LocallyClosed)) => 0,
			Err(_) => -1,
		}
	}));
	result.unwrap_or(-1)
}

/// Write all `len` bytes from `buf` to the stream, blocking until accepted by
/// the QUIC flow-control window. Returns `len`, or -1 on error. Borrows the
/// handle.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_conn_write(
	conn: *mut PancakeIrohConn,
	buf: *const u8,
	len: usize,
) -> isize {
	let result = catch_unwind(AssertUnwindSafe(|| {
		let conn = unsafe { &*conn };
		let src = unsafe { std::slice::from_raw_parts(buf, len) };
		let mut guard = match conn.send.lock() {
			Ok(guard) => guard,
			Err(_) => return -1,
		};
		let send = match guard.as_mut() {
			Some(send) => send,
			None => return -1,
		};
		match conn.rt.block_on(send.write_all(src)) {
			Ok(()) => len as isize,
			Err(_) => -1,
		}
	}));
	result.unwrap_or(-1)
}

/// Report stream health after writes. QUIC transmits written bytes eagerly, so
/// there is no buffered data to push; this returns 0 while the connection is
/// alive and -1 once it is closed or lost. Borrows the handle.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_conn_flush(conn: *mut PancakeIrohConn) -> i32 {
	let result = catch_unwind(AssertUnwindSafe(|| {
		let conn = unsafe { &*conn };
		if conn.conn.close_reason().is_some() {
			-1
		} else {
			0
		}
	}));
	result.unwrap_or(-1)
}

/// Gracefully close the connection: finish the send stream (the partner's read
/// sees clean end of stream) and queue a QUIC close. Idempotent; safe to call
/// before `pancake_iroh_sidecar_conn_free`. Borrows the handle.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_conn_close(conn: *mut PancakeIrohConn) {
	let _ = catch_unwind(AssertUnwindSafe(|| {
		let conn = unsafe { &*conn };
		// On the readiness surface, ownership has already transferred to the
		// tasks. Let the writer drain every admitted byte and finish its stream;
		// closing the QUIC connection here would discard the final owned batch.
		if let Some(nb) = conn.nb.get() {
			if let Ok(mut out) = nb.outbound.lock() {
				out.closed = true;
			}
			nb.close_work.notify_one();
			nb.write_work.notify_one();
			return;
		}
		if let Ok(mut send) = conn.send.try_lock() {
			// Best-effort graceful finish, but only when no writer is mid-call:
			// blocking on `send` here would deadlock a writer parked on QUIC
			// flow control, which the `conn.close()` below is what unblocks.
			if let Some(send) = send.as_mut() {
				let _ = send.finish();
			}
		}
		// The compatibility surface may have a thread parked in a blocking call;
		// close the connection to wake it without waiting on its stream lock.
		conn.conn.close(0u32.into(), b"");
	}));
}

/// Release a connection handle. Closes the connection if still open. Every
/// connection must be freed before its endpoint.
///
/// Safe to call while another thread is parked in a blocking `conn_read` or
/// `conn_write` on the same handle (the teardown a binding hits when it releases
/// a connection whose inbound loop is still parked on a read): closing the QUIC
/// connection makes the parked call return at once, and acquiring both stream
/// locks before the drop fences against it, once the locks are free, no
/// blocking call is still borrowing this box, so the free below cannot race one.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_conn_free(conn: *mut PancakeIrohConn) {
	if conn.is_null() {
		return;
	}
	// Unblock any parked blocking read/write (closes the connection without
	// taking a stream lock, so a writer parked on flow control cannot deadlock).
	pancake_iroh_sidecar_conn_close(conn);
	let nonblocking = unsafe { (&*conn).nb.get().is_some() };
	if !nonblocking {
		let _ = catch_unwind(AssertUnwindSafe(|| {
			let conn_ref = unsafe { &*conn };
			// Fence: wait out an in-flight blocking call. A reader/writer holds
			// `recv`/`send` for the whole `block_on`; once close has unblocked it,
			// acquiring both locks proves the call has returned its borrow. The
			// guards drop at the end of this block, before the box is freed.
			let _recv = conn_ref.recv.lock();
			let _send = conn_ref.send.lock();
		}));
	}
	let _ = catch_unwind(AssertUnwindSafe(|| {
		let inner = *unsafe { Box::from_raw(conn) };
		// The reader has no useful work after local release; abort it. The writer
		// owns every byte `conn_try_write` admitted, so detach it. Its writer permit
		// remains the endpoint's explicit barrier before runtime shutdown, without
		// retaining one completed JoinHandle per lifetime connection.
		if let Some((reader, writer)) = inner.nb_tasks.into_inner() {
			reader.abort();
			drop(writer);
		}
	}));
}

/// Get or lazily create this endpoint's readiness channel. Returns `None` only
/// if the self-pipe could not be created.
fn endpoint_readiness(ep: &PancakeIrohEndpoint) -> Option<&Arc<Readiness>> {
	if ep.readiness.get().is_none() {
		if let Some(r) = Readiness::new() {
			let _ = ep.readiness.set(r);
		}
	}
	ep.readiness.get()
}

/// The reader half of one non-blocking connection: drain the QUIC recv stream
/// into the bounded inbound buffer, signalling `EV_READABLE` as bytes land and
/// `EV_CLOSED` at end of stream or on error. Parks on `read_room` when the
/// buffer is full so a slow loop applies QUIC flow control to the partner.
async fn nb_reader(nb: Arc<NbConn>, mut recv: RecvStream) {
	use iroh::endpoint::{ConnectionError, ReadError};
	loop {
		// Back-pressure: wait while the inbound buffer is at its bound, then ask
		// QUIC for no more than the exact remaining budget. Register the notify
		// before re-checking so a drain that frees room cannot be missed between
		// the check and the await.
		let read_budget = loop {
			let notified = nb.read_room.notified();
			let budget = nb.inbound.lock().unwrap().read_budget();
			if budget > 0 {
				break budget;
			}
			notified.await;
		};
		// `read_chunk` lends the next segment zero-copy out of the stream's
		// reassembly buffer, so this task holds no resident scratch (the old
		// shape was a 64 KiB read buffer held for the connection's lifetime).
		// The one copy is the append into the connection's inbound buffer.
		match recv.read_chunk(read_budget).await {
			Ok(Some(chunk)) => {
				nb.inbound.lock().unwrap().buf.extend_from_slice(&chunk);
				nb.readiness.signal(nb.id, EV_READABLE);
			}
			Ok(None) => {
				nb.inbound.lock().unwrap().eof = true;
				nb.readiness.signal(nb.id, EV_READABLE | EV_CLOSED);
				break;
			}
			// A clean connection-level close is end of stream, not a fault.
			Err(ReadError::ConnectionLost(ConnectionError::ApplicationClosed(_)))
			| Err(ReadError::ConnectionLost(ConnectionError::LocallyClosed)) => {
				nb.inbound.lock().unwrap().eof = true;
				nb.readiness.signal(nb.id, EV_READABLE | EV_CLOSED);
				break;
			}
			Err(_) => {
				nb.inbound.lock().unwrap().err = true;
				nb.readiness.signal(nb.id, EV_CLOSED);
				break;
			}
		}
	}
}

/// The writer half of one non-blocking connection: drain the bounded outbound
/// buffer to the QUIC send stream, signalling `EV_WRITABLE` once a batch flushes.
/// Parks on `write_work` when the buffer is empty; finishes the stream and exits
/// once the loop has closed the connection and the buffer has drained.
async fn nb_writer(nb: Arc<NbConn>, mut send: SendStream) {
	loop {
		let notified = nb.write_work.notified();
		let (chunk, closed) = {
			let mut out = nb.outbound.lock().unwrap();
			// Swap the whole batch with the spare allocation: no copy, and the
			// lock is released before QUIC flow control can suspend this task.
			let chunk = out.take_batch();
			(chunk, out.closed)
		};
		if !chunk.is_empty() {
			let succeeded = {
				let write = send.write_all(&chunk);
				tokio::pin!(write);
				tokio::select! {
					result = &mut write => result.is_ok(),
					_ = nb.close_work.notified() => {
						tokio::time::timeout(CLOSE_DRAIN_TIMEOUT, &mut write)
							.await
							.is_ok_and(|result| result.is_ok())
					}
				}
			};
			nb.outbound.lock().unwrap().finish_batch(chunk, succeeded);
			if !succeeded {
				nb.readiness.signal(nb.id, EV_CLOSED);
				return;
			}
			nb.readiness.signal(nb.id, EV_WRITABLE);
			continue;
		}
		if closed {
			let _ = send.finish();
			return;
		}
		notified.await;
	}
}

/// The acceptor of one endpoint's scale surface: pull incoming connections off
/// the wire into the ready queue and signal `EV_ACCEPT`, so the loop claims them
/// with `endpoint_try_accept` instead of parking a thread in a blocking accept.
async fn nb_acceptor(
	ep: Endpoint,
	connect_timeout: std::time::Duration,
	acc: Arc<AcceptState>,
	readiness: Arc<Readiness>,
) {
	loop {
		let Some(incoming) = ep.accept().await else {
			break;
		};
		let Ok(accepting) = incoming.accept() else {
			continue;
		};
		let Ok(conn) = accepting.await else {
			continue;
		};
		// Same bound on the scale-path acceptor: a half-open dialer is dropped
		// after the timeout rather than stalling this loop's stream accept.
		let Ok(Ok((send, recv))) = tokio::time::timeout(connect_timeout, conn.accept_bi()).await
		else {
			continue;
		};
		let queued = {
			let mut ready = acc.ready.lock().unwrap();
			if ready.len() >= ACCEPT_QUEUE_BOUND {
				false
			} else {
				ready.push_back(AcceptedRaw { conn, send, recv });
				true
			}
		};
		if queued {
			readiness.signal(0, EV_ACCEPT);
		}
	}
}

/// The OS readiness fd for this endpoint's scale surface: the read end of the
/// self-pipe the sidecar nudges whenever a connection (or the acceptor) becomes
/// ready. The completion loop registers this once and polls it; on wake it
/// calls `pancake_iroh_sidecar_endpoint_drain_ready`, which clears the fd's
/// coalesced bytes before it drains records.
/// Returns -1 if the readiness channel could not be created. Borrows the handle;
/// the fd is owned by the endpoint and is valid until
/// `pancake_iroh_sidecar_endpoint_free`.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_endpoint_readiness_fd(
	ep: *const PancakeIrohEndpoint,
) -> i32 {
	let result = catch_unwind(AssertUnwindSafe(|| {
		let ep = unsafe { &*ep };
		match endpoint_readiness(ep) {
			Some(r) => r.reader.as_raw_fd(),
			None => -1,
		}
	}));
	result.unwrap_or(-1)
}

/// Drain pending readiness records into the caller's buffer. `out` points at
/// `out_cap` `PancakeIrohReadyEvent` records; the call writes up to that many and
/// returns the count (>= 0), or -1 on error. No allocation per call. If more
/// records remain queued than fit, the endpoint re-nudges its readiness fd so the
/// loop wakes again to drain the rest. Borrows the handle.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_endpoint_drain_ready(
	ep: *const PancakeIrohEndpoint,
	out: *mut PancakeIrohReadyEvent,
	out_cap: usize,
) -> isize {
	let result = catch_unwind(AssertUnwindSafe(|| {
		let ep = unsafe { &*ep };
		let r = match ep.readiness.get() {
			Some(r) => r,
			None => return 0,
		};
		if out.is_null() || out_cap == 0 {
			return 0;
		}
		let dest = unsafe { std::slice::from_raw_parts_mut(out, out_cap) };
		r.drain(dest) as isize
	}));
	result.unwrap_or(-1)
}

/// Start the non-blocking acceptor for this endpoint: incoming connections are
/// pulled off the wire and surfaced through `endpoint_try_accept` instead of the
/// blocking `accept`. Idempotent. Returns 0 on success, -1 if the readiness
/// channel could not be created. Borrows the handle.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_endpoint_set_nonblocking_accept(
	ep: *mut PancakeIrohEndpoint,
) -> i32 {
	let result = catch_unwind(AssertUnwindSafe(|| {
		let ep = unsafe { &*ep };
		if ep.accept.get().is_some() {
			return 0;
		}
		let readiness = match endpoint_readiness(ep) {
			Some(r) => r.clone(),
			None => return -1,
		};
		let acc = Arc::new(AcceptState {
			ready: Mutex::new(VecDeque::new()),
		});
		if ep.accept.set(acc.clone()).is_err() {
			return 0; // raced with another caller; theirs won
		}
		ep.rt.spawn(nb_acceptor(
			ep.ep.clone(),
			ep.connect_timeout,
			acc,
			readiness,
		));
		0
	}));
	result.unwrap_or(-1)
}

/// Claim one connection the acceptor has pulled off the wire, or null when none
/// is waiting (the non-blocking counterpart of `accept`: null is `WOULD_BLOCK`,
/// not failure, the loop retries on the next `EV_ACCEPT`). The returned handle
/// is a fresh blocking connection; the loop calls `conn_set_nonblocking` on it
/// to bind it to the readiness surface. Returns an owned handle or null. The
/// endpoint must outlive the connection.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_endpoint_try_accept(
	ep: *mut PancakeIrohEndpoint,
) -> *mut PancakeIrohConn {
	let result = catch_unwind(AssertUnwindSafe(|| {
		let ep = unsafe { &*ep };
		let acc = ep.accept.get()?;
		let raw = acc.ready.lock().unwrap().pop_front()?;
		make_conn(ep, raw)
	}));
	match result {
		Ok(Some(handle)) => handle,
		_ => std::ptr::null_mut(),
	}
}

/// Move a connection onto the endpoint's readiness surface: the reader and
/// writer tasks take its streams, and from here `conn_try_read` / `conn_try_write`
/// replace the blocking `conn_read` / `conn_write`. Idempotent. Returns 0 on
/// success, -1 if the endpoint's readiness channel is unavailable or the streams
/// were already taken. `ep` must be the endpoint that minted `conn`. Borrows
/// both handles.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_conn_set_nonblocking(
	ep: *mut PancakeIrohEndpoint,
	conn: *mut PancakeIrohConn,
) -> i32 {
	let result = catch_unwind(AssertUnwindSafe(|| {
		let ep = unsafe { &*ep };
		let conn_ref = unsafe { &*conn };
		let _transition = conn_ref.nonblocking_transition.lock().unwrap();
		if conn_ref.nb.get().is_some() {
			return 0;
		}
		let readiness = match endpoint_readiness(ep) {
			Some(r) => r.clone(),
			None => return -1,
		};
		let send = conn_ref.send.lock().unwrap().take();
		let recv = conn_ref.recv.lock().unwrap().take();
		let (send, recv) = match (send, recv) {
			(Some(s), Some(r)) => (s, r),
			_ => return -1,
		};
		let nb = Arc::new(NbConn {
			readiness: readiness.clone(),
			id: conn_ref.id,
			inbound: Mutex::new(Inbound::default()),
			outbound: Mutex::new(Outbound::default()),
			read_room: Notify::new(),
			write_work: Notify::new(),
			close_work: Notify::new(),
		});
		if conn_ref.nb.set(nb.clone()).is_err() {
			unreachable!("transition lock owns the OnceLock");
		}
		let reader = ep.rt.spawn(nb_reader(nb.clone(), recv));
		let writer_permit = conn_ref.writers.acquire();
		let writer = ep.rt.spawn(async move {
			let _writer_permit = writer_permit;
			nb_writer(nb, send).await;
		});
		let _ = conn_ref.nb_tasks.set((reader, writer));
		// The connection starts writable: the loop may flush as soon as it has
		// bytes to send.
		readiness.signal(conn_ref.id, EV_WRITABLE);
		0
	}));
	result.unwrap_or(-1)
}

/// Stable readiness identity for a connection. It is unique for the endpoint's
/// lifetime and never derived from the allocation address.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_conn_id(conn: *const PancakeIrohConn) -> usize {
	let result = catch_unwind(AssertUnwindSafe(|| {
		if conn.is_null() {
			return 0;
		}
		unsafe { (*conn).id }
	}));
	result.unwrap_or(0)
}

/// Non-blocking read: copy up to `len` buffered inbound bytes into `buf`. Returns
/// the byte count (> 0), 0 at clean end of stream, -1 on error, or
/// `PANCAKE_IROH_WOULD_BLOCK` (-2) when no bytes are buffered yet. Draining the
/// buffer frees room for the reader task to resume. The connection must have been
/// moved to the readiness surface with `conn_set_nonblocking`. Borrows the handle.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_conn_try_read(
	conn: *mut PancakeIrohConn,
	buf: *mut u8,
	len: usize,
) -> isize {
	let result = catch_unwind(AssertUnwindSafe(|| {
		let conn = unsafe { &*conn };
		let nb = match conn.nb.get() {
			Some(nb) => nb,
			None => return -1,
		};
		let mut inb = nb.inbound.lock().unwrap();
		let pending = inb.pending();
		if pending > 0 {
			let n = std::cmp::min(len, pending);
			if n > 0 {
				let dest = unsafe { std::slice::from_raw_parts_mut(buf, n) };
				dest.copy_from_slice(&inb.buf[inb.off..inb.off + n]);
				inb.off += n;
			}
			if inb.off == inb.buf.len() {
				// Empty transition: reset, and free burst capacity down to the
				// steady bound (the Zig loop's posture, loop.zig) so one
				// slow-reader episode never pins its high-water bytes. Runs
				// only here — never on the reader's append path — so it adds
				// no hot-path contention.
				inb.buf.clear();
				inb.off = 0;
				if inb.buf.capacity() > NB_STEADY_BYTES {
					inb.buf.shrink_to(NB_STEADY_BYTES);
				}
			} else if inb.off >= inb.buf.len() - inb.off {
				// The consumed prefix has outgrown the pending bytes: compact
				// so `buf.len()` tracks the bounded pending count instead of
				// the total bytes ever buffered. Amortized O(1) per drained
				// byte, and the moved span is capped by the flow-control
				// bound.
				let off = inb.off;
				inb.buf.copy_within(off.., 0);
				let pending_len = inb.buf.len() - off;
				inb.buf.truncate(pending_len);
				inb.off = 0;
			}
			drop(inb);
			nb.read_room.notify_one();
			return n as isize;
		}
		if inb.eof {
			return 0;
		}
		if inb.err {
			return -1;
		}
		WOULD_BLOCK
	}));
	result.unwrap_or(-1)
}

/// Non-blocking write: copy the prefix that fits into the bounded outbound
/// buffer and wake the writer task. Returns the admitted byte count,
/// `PANCAKE_IROH_WOULD_BLOCK` (-2) when no outbound room remains, and -1 on
/// error. The connection must have been moved to the readiness surface with
/// `conn_set_nonblocking`. Borrows the handle.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_conn_try_write(
	conn: *mut PancakeIrohConn,
	buf: *const u8,
	len: usize,
) -> isize {
	let result = catch_unwind(AssertUnwindSafe(|| {
		let conn = unsafe { &*conn };
		let nb = match conn.nb.get() {
			Some(nb) => nb,
			None => return -1,
		};
		if len == 0 {
			return 0;
		}
		let src = unsafe { std::slice::from_raw_parts(buf, len) };
		let accepted = {
			let mut out = nb.outbound.lock().unwrap();
			enqueue_outbound(&mut out, src)
		};
		if accepted > 0 {
			nb.write_work.notify_one();
		}
		accepted
	}));
	result.unwrap_or(-1)
}

/// Close the endpoint without releasing its handle: an in-flight bounded accept
/// returns null, subsequent dials fail, and queued connection closes are
/// delivered. Idempotent. Borrows the handle; the handle stays valid until
/// `pancake_iroh_sidecar_endpoint_free`.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_endpoint_close(ep: *mut PancakeIrohEndpoint) {
	let _ = catch_unwind(AssertUnwindSafe(|| {
		let ep = unsafe { &*ep };
		if let Some(dials) = ep.dials.get() {
			dials.cancel_all();
		}
		ep.rt.block_on(ep.ep.close());
	}));
}

/// Release an endpoint handle. Blocks while iroh delivers queued connection
/// closes, then shuts the runtime down. Free every connection minted from this
/// endpoint first.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_endpoint_free(ep: *mut PancakeIrohEndpoint) {
	if ep.is_null() {
		return;
	}
	let _ = catch_unwind(AssertUnwindSafe(|| {
		let handle = unsafe { Box::from_raw(ep) };
		if let Some(dials) = handle.dials.get() {
			dials.cancel_all();
		}
		handle.rt.block_on(handle.writers.wait());
		handle.rt.block_on(handle.ep.close());
		// Dropping the runtime outside an async context shuts it down cleanly.
		drop(handle);
	}));
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::io::{Read, Write};
	use std::net::UdpSocket;
	use std::sync::atomic::AtomicBool;
	use std::time::{Duration, Instant};

	fn direct_endpoint(connect_timeout_ms: u64) -> *mut PancakeIrohEndpoint {
		let config = PancakeIrohEndpointConfig {
			reachability: REACH_DIRECT,
			connect_timeout_ms,
			idle_timeout_ms: 0,
			worker_threads: 0,
		};
		pancake_iroh_sidecar_endpoint_new(std::ptr::null(), &config)
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

		readiness.signal(7, EV_READABLE);
		let mut byte = [0u8; 1];
		let mut reader = &readiness.reader;
		assert_eq!(reader.read(&mut byte).unwrap(), 1);
		assert_eq!(readiness.queue.lock().unwrap().len(), 1);
	}

	#[test]
	fn drain_owns_wake_bytes_and_the_exported_half_is_read_only() {
		let readiness = Readiness::new().unwrap();
		let mut exported = &readiness.reader;
		assert!(exported.write_all(&[1]).is_err());

		readiness.signal(7, EV_WRITABLE);
		let mut events = [PancakeIrohReadyEvent {
			subject: 0,
			events: 0,
		}];
		assert_eq!(readiness.drain(&mut events), 1);
		assert_eq!(events[0].subject, 7);
		assert_eq!(events[0].events, EV_WRITABLE);

		let mut byte = [0u8; 1];
		let err = exported.read(&mut byte).unwrap_err();
		assert_eq!(err.kind(), std::io::ErrorKind::WouldBlock);
	}

	#[test]
	fn readiness_queue_coalesces_without_losing_distinct_subjects() {
		let readiness = Readiness::new().unwrap();
		const SUBJECTS: usize = 20_000;
		for subject in 1..=SUBJECTS {
			readiness.signal(subject, EV_READABLE);
		}
		assert_eq!(readiness.queue.lock().unwrap().len(), SUBJECTS);

		readiness.signal(7, EV_WRITABLE);
		assert_eq!(readiness.queue.lock().unwrap().len(), SUBJECTS);

		let mut events = vec![
			PancakeIrohReadyEvent {
				subject: 0,
				events: 0,
			};
			SUBJECTS
		];
		assert_eq!(readiness.drain(&mut events), SUBJECTS);
		assert_eq!(events[6].subject, 7);
		assert_eq!(events[6].events, EV_READABLE | EV_WRITABLE);
		assert_eq!(events.last().unwrap().subject, SUBJECTS);
	}

	#[test]
	fn outbound_bound_admits_a_prefix_and_blocks_only_when_full() {
		let mut outbound = Outbound::default();
		outbound.in_flight = NB_BUFFER_BOUND - 4;

		let bytes = [9u8; 16];
		assert_eq!(enqueue_outbound(&mut outbound, &bytes), 4);
		assert_eq!(outbound.pending(), NB_BUFFER_BOUND);
		assert_eq!(enqueue_outbound(&mut outbound, &bytes), WOULD_BLOCK);
	}

	#[test]
	fn inbound_read_budget_never_exceeds_remaining_capacity() {
		let mut inbound = Inbound::default();
		assert_eq!(inbound.read_budget(), READ_CHUNK_BYTES);

		inbound.buf.resize(NB_BUFFER_BOUND - 7, 0);
		assert_eq!(inbound.read_budget(), 7);

		inbound.buf.resize(NB_BUFFER_BOUND, 0);
		assert_eq!(inbound.read_budget(), 0);
	}

	#[test]
	fn outbound_reuses_one_steady_spare_without_double_spending_the_bound() {
		let mut outbound = Outbound::default();
		let bytes = vec![9u8; NB_STEADY_BYTES];
		assert_eq!(
			enqueue_outbound(&mut outbound, &bytes),
			NB_STEADY_BYTES as isize
		);

		let batch = outbound.take_batch();
		assert_eq!(outbound.pending(), NB_STEADY_BYTES);
		assert_eq!(
			enqueue_outbound(&mut outbound, &bytes),
			NB_STEADY_BYTES as isize
		);
		outbound.finish_batch(batch, true);

		let spare_ptr = outbound.spare.as_ptr();
		let second = outbound.take_batch();
		assert_eq!(outbound.buf.as_ptr(), spare_ptr);
		assert_eq!(outbound.pending(), NB_STEADY_BYTES);
		outbound.finish_batch(second, true);
		assert!(outbound.spare.capacity() <= NB_STEADY_BYTES);
	}

	#[test]
	fn blocking_accept_timeout_does_not_arm_or_drain_readiness() {
		let ep = direct_endpoint(200);
		assert!(!ep.is_null(), "endpoint_new");
		let started = Instant::now();
		let conn = pancake_iroh_sidecar_accept_timeout(ep, 20);
		assert!(conn.is_null());
		assert!(started.elapsed() >= Duration::from_millis(5));
		assert!(started.elapsed() < Duration::from_secs(1));
		let endpoint = unsafe { &*ep };
		assert!(endpoint.readiness.get().is_none());
		assert!(endpoint.accept.get().is_none());
		pancake_iroh_sidecar_endpoint_free(ep);
	}

	#[test]
	fn endpoint_release_joins_writers_detached_by_connection_release() {
		let ep = direct_endpoint(200);
		assert!(!ep.is_null(), "endpoint_new");
		let finished = Arc::new(AtomicBool::new(false));
		let task_finished = finished.clone();
		let endpoint = unsafe { &*ep };
		let permit = endpoint.writers.acquire();
		let writer = endpoint.rt.spawn(async move {
			let _permit = permit;
			tokio::time::sleep(Duration::from_millis(20)).await;
			task_finished.store(true, Ordering::Release);
		});
		drop(writer);

		pancake_iroh_sidecar_endpoint_free(ep);
		assert!(
			finished.load(Ordering::Acquire),
			"runtime shutdown abandoned a writer whose connection transferred ownership"
		);
	}

	fn black_hole_target() -> (UdpSocket, String, String) {
		// Keeping the port bound prevents an ICMP port-unreachable from turning
		// the intended pending dial into an immediate failure.
		let socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).expect("bind black hole");
		let hint = socket.local_addr().expect("black hole addr").to_string();
		let endpoint_id = SecretKey::from([7u8; 32]).public().to_string();
		(socket, endpoint_id, hint)
	}

	fn wait_event(ep: *mut PancakeIrohEndpoint) -> PancakeIrohReadyEvent {
		let deadline = Instant::now() + Duration::from_secs(5);
		let mut events = [PancakeIrohReadyEvent {
			subject: 0,
			events: 0,
		}; 4];
		loop {
			let n =
				pancake_iroh_sidecar_endpoint_drain_ready(ep, events.as_mut_ptr(), events.len());
			if n > 0 {
				return events[0];
			}
			assert!(Instant::now() < deadline, "timed out waiting for readiness");
			std::thread::sleep(Duration::from_millis(10));
		}
	}

	/// A short caller-set connect timeout must trip fast. The dial's only route is
	/// a bound-but-silent UDP black hole: because the port is bound, the OS never
	/// answers the QUIC handshake and never sends an ICMP port-unreachable that
	/// would fail the dial fast, so the connect can end only by the deadline. A
	/// 200ms endpoint therefore publishes a timeout in well under the 30s default,
	/// proving the per-endpoint `connect_timeout` reaches the connect await rather
	/// than merely that some dial eventually fails. Hermetic: `REACH_DIRECT` binds
	/// relay-less and lookup-less, and every address is loopback.
	#[test]
	fn evented_connect_returns_promptly_and_times_out_once() {
		let (_black_hole, unreachable_id, hint) = black_hole_target();
		// 200ms per-endpoint deadline; direct reachability so the dial uses only
		// our hint (no discovery, no relays), leaving the black hole the sole route.
		let ep = direct_endpoint(200);
		assert!(!ep.is_null(), "endpoint_new");

		let started = Instant::now();
		let code = pancake_iroh_sidecar_endpoint_start_connect(
			ep,
			1,
			unreachable_id.as_ptr(),
			unreachable_id.len(),
			hint.as_ptr(),
			hint.len(),
		);
		assert_eq!(code, DIAL_OK);
		assert!(
			started.elapsed() < Duration::from_millis(100),
			"start_connect must return promptly"
		);

		let event = wait_event(ep);
		assert_eq!(event.subject, 1);
		assert_eq!(event.events, EV_CONNECT);

		let mut conn = std::ptr::null_mut();
		assert_eq!(
			pancake_iroh_sidecar_endpoint_finish_connect(ep, 1, &mut conn),
			DIAL_TIMEOUT
		);
		assert!(conn.is_null());
		assert_eq!(
			pancake_iroh_sidecar_endpoint_finish_connect(ep, 1, &mut conn),
			DIAL_INVALID,
			"terminal result is one-shot"
		);
		let mut events = [PancakeIrohReadyEvent {
			subject: 0,
			events: 0,
		}; 1];
		assert_eq!(
			pancake_iroh_sidecar_endpoint_drain_ready(ep, events.as_mut_ptr(), events.len()),
			0,
			"one admitted dial emits exactly one terminal event"
		);

		pancake_iroh_sidecar_endpoint_free(ep);
	}

	#[test]
	fn rejected_connect_owes_no_event() {
		let ep = direct_endpoint(200);
		assert!(!ep.is_null(), "endpoint_new");
		let invalid = b"not-an-endpoint-id";
		assert_eq!(
			pancake_iroh_sidecar_endpoint_start_connect(
				ep,
				1,
				invalid.as_ptr(),
				invalid.len(),
				std::ptr::null(),
				0,
			),
			DIAL_INVALID
		);
		let mut event = PancakeIrohReadyEvent {
			subject: 0,
			events: 0,
		};
		assert_eq!(
			pancake_iroh_sidecar_endpoint_drain_ready(ep, &mut event, 1),
			0
		);
		pancake_iroh_sidecar_endpoint_free(ep);
	}

	#[test]
	fn evented_connect_admission_is_bounded_and_reclaimed() {
		let (_black_hole, unreachable_id, hint) = black_hole_target();
		let ep = direct_endpoint(5_000);
		assert!(!ep.is_null(), "endpoint_new");

		for request_id in 1..=DIAL_ADMISSION_BOUND {
			assert_eq!(
				pancake_iroh_sidecar_endpoint_start_connect(
					ep,
					request_id,
					unreachable_id.as_ptr(),
					unreachable_id.len(),
					hint.as_ptr(),
					hint.len(),
				),
				DIAL_OK
			);
		}
		assert_eq!(
			pancake_iroh_sidecar_endpoint_start_connect(
				ep,
				DIAL_ADMISSION_BOUND + 1,
				unreachable_id.as_ptr(),
				unreachable_id.len(),
				hint.as_ptr(),
				hint.len(),
			),
			DIAL_BUSY
		);

		for request_id in 1..=DIAL_ADMISSION_BOUND {
			assert_eq!(
				pancake_iroh_sidecar_endpoint_cancel_connect(ep, request_id),
				DIAL_OK
			);
			let mut conn = std::ptr::null_mut();
			assert_eq!(
				pancake_iroh_sidecar_endpoint_finish_connect(ep, request_id, &mut conn),
				DIAL_CANCELED
			);
		}

		let replacement_id = DIAL_ADMISSION_BOUND + 2;
		assert_eq!(
			pancake_iroh_sidecar_endpoint_start_connect(
				ep,
				replacement_id,
				unreachable_id.as_ptr(),
				unreachable_id.len(),
				hint.as_ptr(),
				hint.len(),
			),
			DIAL_OK
		);
		assert_eq!(
			pancake_iroh_sidecar_endpoint_cancel_connect(ep, replacement_id),
			DIAL_OK
		);
		let mut conn = std::ptr::null_mut();
		assert_eq!(
			pancake_iroh_sidecar_endpoint_finish_connect(ep, replacement_id, &mut conn),
			DIAL_CANCELED
		);
		pancake_iroh_sidecar_endpoint_free(ep);
	}

	#[test]
	fn canceled_connect_finishes_once() {
		let (_black_hole, unreachable_id, hint) = black_hole_target();
		let ep = direct_endpoint(5_000);
		assert!(!ep.is_null(), "endpoint_new");
		assert_eq!(
			pancake_iroh_sidecar_endpoint_start_connect(
				ep,
				23,
				unreachable_id.as_ptr(),
				unreachable_id.len(),
				hint.as_ptr(),
				hint.len(),
			),
			DIAL_OK
		);
		assert_eq!(
			pancake_iroh_sidecar_endpoint_cancel_connect(ep, 23),
			DIAL_OK
		);
		assert_eq!(
			pancake_iroh_sidecar_endpoint_cancel_connect(ep, 23),
			DIAL_OK,
			"cancel is idempotent while the terminal row exists"
		);

		let event = wait_event(ep);
		assert_eq!(event.subject, 23);
		assert_eq!(event.events, EV_CONNECT);
		let mut conn = std::ptr::null_mut();
		assert_eq!(
			pancake_iroh_sidecar_endpoint_finish_connect(ep, 23, &mut conn),
			DIAL_CANCELED
		);
		assert!(conn.is_null());
		assert_eq!(
			pancake_iroh_sidecar_endpoint_finish_connect(ep, 23, &mut conn),
			DIAL_INVALID
		);
		pancake_iroh_sidecar_endpoint_free(ep);
	}
}
