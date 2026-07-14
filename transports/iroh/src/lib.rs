//! The iroh netlayer sidecar (ADR-0055).
//!
//! This staticlib wraps one iroh endpoint behind the narrow blocking C ABI
//! declared in `include/pancake_iroh_sidecar.h`, emitting
//! `libpancake_iroh_sidecar.a`. The Zig resident
//! (`src/net/transport/iroh.zig`) is the only consumer. Shape decisions:
//!
//! * Each endpoint owns its own tokio runtime behind the opaque handle, so a
//!   caller needs no async runtime of its own; every C call blocks the calling
//!   thread by running `block_on` against that runtime. The runtime's thread
//!   bill is explicit and bounded: two worker threads named `pancake-iroh`,
//!   enough for iroh's internal driver tasks while the caller's own threads do
//!   the blocking.
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

use std::collections::{BTreeSet, VecDeque};
use std::io::Write as _;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::str::FromStr;
use std::sync::{Arc, Mutex, OnceLock};

use iroh::address_lookup::memory::MemoryLookup;
use iroh::endpoint::{presets, Connection, RecvStream, SendStream};
use iroh::{Endpoint, EndpointAddr, EndpointId, SecretKey};
use tokio::sync::Notify;
use tokio::task::JoinHandle;

/// The ALPN both pancake peers negotiate (ADR-0055).
const ALPN: &[u8] = b"ocapn/pancake/1";

/// Upper bound on a single dial, discovery resolution plus relay/hole-punch
/// setup. A dial that cannot be established within this window returns null (the
/// Zig resident maps that to `error.ConnectionLost`) instead of parking the
/// calling thread forever. Loopback and in-process dials complete in
/// milliseconds, so this bounds only the public-discovery path, where it keeps a
/// failed dial from hanging a gate or a caller.
const CONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

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
/// buffer is at its bound. The loop yields the connection and re-arms it on the
/// next readiness event. Distinct from `0` (clean end of stream) and `-1`
/// (error). Mirrors `PANCAKE_IROH_WOULD_BLOCK` in the header and the Zig
/// resident.
const WOULD_BLOCK: isize = -2;

/// Readiness event bits packed into `PancakeIrohReadyEvent.events`. A single
/// drained record may carry several at once (e.g. `EV_READABLE | EV_CLOSED` when
/// the peer's last bytes arrive with its end of stream).
const EV_READABLE: u32 = 1;
const EV_WRITABLE: u32 = 2;
const EV_CLOSED: u32 = 4;
const EV_ACCEPT: u32 = 8;

/// The non-blocking inbound/outbound buffer bound, per connection and direction
/// (ADR-0057's back-pressure policy). A reader that fills the inbound buffer
/// stops reading the QUIC stream until the loop drains it, so a slow consumer
/// applies QUIC flow control to its partner rather than letting the sidecar
/// buffer without limit; a `conn_try_write` past the outbound bound returns
/// `WOULD_BLOCK`. One largest-admissible CapTP frame fits well within this, so
/// steady traffic never blocks on it.
const NB_BUFFER_BOUND: usize = 1 << 20;

/// The steady per-direction buffer capacity a connection retains once a burst
/// drains, mirroring the Zig loop's posture (`loop_read_buf_bytes` and
/// `steady_outbound_bytes` in `src/net/completion/loop.zig`, both 16 KiB):
/// burst capacity frees on drain so one slow episode never pins its high-water
/// bytes for the connection's lifetime, while steady-sized capacity is retained
/// so ordinary traffic never reallocates.
const NB_STEADY_BYTES: usize = 16 * 1024;

/// Cap on one `read_chunk` segment in the reader task. The chunk is a zero-copy
/// borrow of the QUIC reassembly buffer, so the cap costs no memory; it bounds
/// how far one read may overshoot `NB_BUFFER_BOUND` (the bound is checked
/// before the read, so pending bytes never exceed `NB_BUFFER_BOUND +
/// READ_CHUNK_BYTES`), matching the previous 64 KiB read granularity.
const READ_CHUNK_BYTES: usize = 64 * 1024;

/// One drained readiness record: the connection that became ready (its
/// `PancakeIrohConn` pointer as an integer, or null for an `EV_ACCEPT` record)
/// and the `EV_*` bitset describing how. `#[repr(C)]` so the Zig resident reads
/// the identical layout; kept in lockstep with `pancake_iroh_sidecar_ready_event`
/// in the header and `ReadyEvent` in the resident.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct PancakeIrohReadyEvent {
	conn: usize,
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
	readiness: OnceLock<Arc<Readiness>>,
	accept: OnceLock<Arc<AcceptState>>,
}

/// Opaque connection handle: one QUIC connection carrying one bidirectional
/// stream. `send` and `recv` are independently locked so the two directions
/// never serialize against each other; they are `Option` because
/// `conn_set_nonblocking` moves the streams out to the reader/writer tasks,
/// after which the blocking calls refuse (the connection is owned by the loop).
/// `nb` holds the non-blocking state once that transition happens.
pub struct PancakeIrohConn {
	rt: tokio::runtime::Handle,
	conn: Connection,
	send: Mutex<Option<SendStream>>,
	recv: Mutex<Option<RecvStream>>,
	nb: OnceLock<Arc<NbConn>>,
	/// The reader/writer task handles. `conn_free` aborts and joins them
	/// before this box's address is freed, so a stale task can never signal
	/// readiness under a pointer a later connection reuses (ABA).
	nb_tasks: OnceLock<(JoinHandle<()>, JoinHandle<()>)>,
}

/// One endpoint's readiness channel: the self-pipe the loop polls plus the queue
/// of pending `(conn, events)` records. Every readiness signal appends to
/// `queue` and writes one byte to `writer`, so a loop blocked on the read end
/// wakes and drains the queue.
struct Readiness {
	/// The read end the loop polls; `endpoint_readiness_fd` returns its fd.
	reader: UnixStream,
	/// The write end, set non-blocking so a coalesced wakeup never parks a task;
	/// the queue, not the byte count, is the source of truth.
	writer: Mutex<UnixStream>,
	queue: Mutex<VecDeque<PancakeIrohReadyEvent>>,
}

impl Readiness {
	fn new() -> Option<Arc<Readiness>> {
		let (reader, writer) = UnixStream::pair().ok()?;
		// Both ends non-blocking: the loop drains the read end without parking,
		// and a coalesced wakeup never blocks a signalling task on a full pipe.
		reader.set_nonblocking(true).ok()?;
		writer.set_nonblocking(true).ok()?;
		Some(Arc::new(Readiness {
			reader,
			writer: Mutex::new(writer),
			queue: Mutex::new(VecDeque::new()),
		}))
	}

	/// Enqueue one readiness record and nudge the self-pipe. The wakeup byte is
	/// best-effort: the queue already carries the event, so a full pipe (an
	/// undrained backlog) is harmless, the loop is already going to wake.
	fn signal(&self, conn: usize, events: u32) {
		self.queue
			.lock()
			.unwrap()
			.push_back(PancakeIrohReadyEvent { conn, events });
		if let Ok(mut w) = self.writer.lock() {
			let _ = w.write(&[1u8]);
		}
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

/// Non-blocking state for one connection: the bounded inbound/outbound buffers
/// the reader and writer tasks move bytes through, the notifies that wake those
/// tasks, and the endpoint readiness this connection signals into. The reader
/// and writer tasks own the QUIC streams (moved out of `PancakeIrohConn`), so
/// they can hold them across `.await` without a `!Send` guard.
struct NbConn {
	readiness: Arc<Readiness>,
	/// This connection's `PancakeIrohConn` pointer as an integer, the identity
	/// the loop matches drained records against.
	id: usize,
	inbound: Mutex<Inbound>,
	outbound: Mutex<Outbound>,
	/// Woken when the loop drains the inbound buffer: the reader parks here when
	/// the inbound buffer is at its bound and resumes when room frees.
	read_room: Notify,
	/// Woken when the loop enqueues outbound bytes or closes the connection: the
	/// writer parks here when the outbound buffer is empty.
	write_work: Notify,
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
}

#[derive(Default)]
struct Outbound {
	/// The queued batch. The writer task takes the whole buffer (a move, no
	/// copy) and drops its storage once flushed, so outbound burst capacity
	/// never outlives the batch that needed it.
	buf: Vec<u8>,
	/// Set by `conn_close` / `conn_free`: the writer finishes the send stream
	/// and exits once the buffer drains.
	closed: bool,
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
	reachability: u32,
) -> *mut PancakeIrohEndpoint {
	let result = catch_unwind(AssertUnwindSafe(|| {
		let rt = tokio::runtime::Builder::new_multi_thread()
			.worker_threads(2)
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
		Some(Box::into_raw(Box::new(PancakeIrohEndpoint {
			rt,
			ep,
			readiness: OnceLock::new(),
			accept: OnceLock::new(),
		})))
	}));
	match result {
		Ok(Some(handle)) => handle,
		_ => std::ptr::null_mut(),
	}
}

/// Write a UTF-8 string into a caller buffer. Returns the byte count written,
/// or -1 when the buffer is too small.
fn write_str(s: &str, out: *mut u8, out_cap: usize) -> isize {
	let bytes = s.as_bytes();
	if bytes.len() > out_cap {
		return -1;
	}
	// Safety: the contract requires `out_cap` writable bytes at `out`.
	unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, bytes.len()) };
	bytes.len() as isize
}

/// Write the endpoint's id — its Ed25519 public key, the dialable designator —
/// into `out` as lowercase hex (64 bytes; iroh's canonical string form, which
/// its parser accepts alongside base32). Returns the byte count written, or -1
/// when `out_cap` is too small. Borrows the handle; writes no terminator.
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
/// as-is. This is the hint string a partner passes to `pancake_iroh_sidecar_connect`.
/// Returns the byte count written, or -1 when `out_cap` is too small. Borrows
/// the handle; writes no terminator.
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

/// Dial a remote endpoint by id, open the session's one bidirectional stream,
/// and return an owned connection handle (release with
/// `pancake_iroh_sidecar_conn_free`), or null on failure. `node_id` is the partner's id
/// string (hex or base32, as printed by `pancake_iroh_sidecar_endpoint_node_id`);
/// `addr_hints` is the partner's comma-separated direct-address list. It may be
/// empty: an endpoint bound with a discovery posture (`REACH_DISCOVERY`,
/// `REACH_DISCOVERY_NO_RELAY`, or `REACH_LOCAL_DISCOVERY`) resolves the partner
/// by id alone, while a `REACH_DIRECT` endpoint needs the hints to reach
/// anything. Blocks
/// until the QUIC connection is established. The stream is lazy: the caller
/// must write first (OCapN's dialer does, with `op:start-session`). The
/// endpoint must outlive every connection it minted.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_connect(
	ep: *mut PancakeIrohEndpoint,
	node_id: *const u8,
	node_id_len: usize,
	addr_hints: *const u8,
	addr_hints_len: usize,
) -> *mut PancakeIrohConn {
	let result = catch_unwind(AssertUnwindSafe(|| {
		let ep = unsafe { &*ep };
		let id_str =
			std::str::from_utf8(unsafe { std::slice::from_raw_parts(node_id, node_id_len) })
				.ok()?;
		let id = EndpointId::from_str(id_str).ok()?;
		let mut addr = EndpointAddr::new(id);
		if addr_hints_len > 0 {
			let hints = std::str::from_utf8(unsafe {
				std::slice::from_raw_parts(addr_hints, addr_hints_len)
			})
			.ok()?;
			for hint in hints.split(',') {
				let hint = hint.trim();
				if hint.is_empty() {
					continue;
				}
				let sock = SocketAddr::from_str(hint).ok()?;
				addr = addr.with_ip_addr(sock);
			}
		}
		// Bound the dial so a partner that never resolves or never answers
		// fails closed instead of parking this thread forever. A failed or
		// timed-out dial logs its cause to stderr — the sidecar's only output —
		// so a discovery or relay fault is diagnosable instead of a bare null.
		let conn = match ep.rt.block_on(async {
			tokio::time::timeout(CONNECT_TIMEOUT, ep.ep.connect(addr, ALPN)).await
		}) {
			Ok(Ok(conn)) => conn,
			Ok(Err(e)) => {
				eprintln!("pancake-iroh: connect failed: {e:?}");
				return None;
			}
			Err(_) => {
				eprintln!("pancake-iroh: connect timed out after {CONNECT_TIMEOUT:?}");
				return None;
			}
		};
		// Bound the stream open too: a partner that completes the QUIC
		// handshake but never services the bidirectional stream (a reconnect
		// race) would otherwise park this thread forever, past the connect
		// timeout above. Fail closed with the same shape.
		let (send, recv) = match ep
			.rt
			.block_on(async { tokio::time::timeout(CONNECT_TIMEOUT, conn.open_bi()).await })
		{
			Ok(Ok(streams)) => streams,
			Ok(Err(e)) => {
				eprintln!("pancake-iroh: open_bi failed: {e:?}");
				return None;
			}
			Err(_) => {
				eprintln!("pancake-iroh: open_bi timed out after {CONNECT_TIMEOUT:?}");
				return None;
			}
		};
		Some(Box::into_raw(Box::new(PancakeIrohConn {
			rt: ep.rt.handle().clone(),
			conn,
			send: Mutex::new(Some(send)),
			recv: Mutex::new(Some(recv)),
			nb: OnceLock::new(),
			nb_tasks: OnceLock::new(),
		})))
	}));
	match result {
		Ok(Some(handle)) => handle,
		_ => std::ptr::null_mut(),
	}
}

/// Block until a partner dials this endpoint, accept its connection and its
/// first bidirectional stream, and return an owned connection handle (release
/// with `pancake_iroh_sidecar_conn_free`), or null on failure or endpoint close.
/// Because QUIC bi streams are lazy, this returns only once the dialer has
/// written its first bytes (OCapN's `op:start-session`). The endpoint must
/// outlive every connection it minted.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_accept(
	ep: *mut PancakeIrohEndpoint,
) -> *mut PancakeIrohConn {
	let result = catch_unwind(AssertUnwindSafe(|| {
		let ep = unsafe { &*ep };
		ep.rt.block_on(async {
			loop {
				let incoming = ep.ep.accept().await?;
				let Ok(accepting) = incoming.accept() else {
					// Unsolicited or malformed datagrams are routine; keep
					// accepting.
					continue;
				};
				let Ok(conn) = accepting.await else {
					continue;
				};
				// Bound the stream accept: a dialer that opens the QUIC
				// connection but never its bidirectional stream is dropped
				// after the timeout instead of holding the acceptor. A stalled
				// or failed accept keeps serving the next incoming.
				let Ok(Ok((send, recv))) =
					tokio::time::timeout(CONNECT_TIMEOUT, conn.accept_bi()).await
				else {
					continue;
				};
				return Some(Box::into_raw(Box::new(PancakeIrohConn {
					rt: ep.rt.handle().clone(),
					conn,
					send: Mutex::new(Some(send)),
					recv: Mutex::new(Some(recv)),
					nb: OnceLock::new(),
					nb_tasks: OnceLock::new(),
				})));
			}
		})
	}));
	match result {
		Ok(Some(handle)) => handle,
		_ => std::ptr::null_mut(),
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
		// Non-blocking: the writer task owns the send stream, so signal it to
		// finish and let it drain whatever is still queued before exiting.
		if let Some(nb) = conn.nb.get() {
			if let Ok(mut out) = nb.outbound.lock() {
				out.closed = true;
			}
			nb.write_work.notify_one();
		} else if let Ok(mut send) = conn.send.try_lock() {
			// Best-effort graceful finish, but only when no writer is mid-call:
			// blocking on `send` here would deadlock a writer parked on QUIC
			// flow control, which the `conn.close()` below is what unblocks.
			if let Some(send) = send.as_mut() {
				let _ = send.finish();
			}
		}
		// Unblock any parked blocking read/write without holding a stream lock.
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
	let _ = catch_unwind(AssertUnwindSafe(|| {
		let conn_ref = unsafe { &*conn };
		// Fence: wait out an in-flight blocking call. A reader/writer holds
		// `recv`/`send` for the whole `block_on`; once close has unblocked it,
		// acquiring both locks proves the call has returned its borrow. The
		// guards drop at the end of this block, before the box is freed.
		let _recv = conn_ref.recv.lock();
		let _send = conn_ref.send.lock();
	}));
	let _ = catch_unwind(AssertUnwindSafe(|| {
		let inner = *unsafe { Box::from_raw(conn) };
		// Stop the reader/writer tasks before this box's address is reusable,
		// so a stale task can never signal readiness under a pointer a later
		// connection reuses (ABA). Abort, then join so none outlives the free.
		if let Some((reader, writer)) = inner.nb_tasks.into_inner() {
			reader.abort();
			writer.abort();
			inner.rt.block_on(async {
				let _ = reader.await;
				let _ = writer.await;
			});
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
		// Back-pressure: wait while the inbound buffer is at its bound. Register
		// the notify before re-checking so a drain that frees room cannot be
		// missed between the check and the await.
		loop {
			let notified = nb.read_room.notified();
			if nb.inbound.lock().unwrap().pending() < NB_BUFFER_BOUND {
				break;
			}
			notified.await;
		}
		// `read_chunk` lends the next segment zero-copy out of the stream's
		// reassembly buffer, so this task holds no resident scratch (the old
		// shape was a 64 KiB read buffer held for the connection's lifetime).
		// The one copy is the append into the connection's inbound buffer.
		match recv.read_chunk(READ_CHUNK_BYTES).await {
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
			// Take the whole batch by move — no allocation, no copy — so the
			// lock is released before the await below. The taken storage drops
			// at the end of this iteration, which also returns a burst's
			// capacity instead of pinning the high-water mark for the
			// connection's lifetime.
			(std::mem::take(&mut out.buf), out.closed)
		};
		if !chunk.is_empty() {
			if send.write_all(&chunk).await.is_err() {
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
async fn nb_acceptor(ep: Endpoint, acc: Arc<AcceptState>, readiness: Arc<Readiness>) {
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
		let Ok(Ok((send, recv))) = tokio::time::timeout(CONNECT_TIMEOUT, conn.accept_bi()).await
		else {
			continue;
		};
		acc.ready
			.lock()
			.unwrap()
			.push_back(AcceptedRaw { conn, send, recv });
		readiness.signal(0, EV_ACCEPT);
	}
}

/// The OS readiness fd for this endpoint's scale surface: the read end of the
/// self-pipe the sidecar nudges whenever a connection (or the acceptor) becomes
/// ready. The completion loop registers this once and polls it; on wake it
/// drains the fd's bytes and calls `pancake_iroh_sidecar_endpoint_drain_ready`.
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
		let mut q = r.queue.lock().unwrap();
		let n = std::cmp::min(out_cap, q.len());
		for slot in dest.iter_mut().take(n) {
			*slot = q.pop_front().unwrap();
		}
		let remaining = !q.is_empty();
		drop(q);
		// A backlog larger than the buffer must still wake the loop: nudge the
		// pipe so the next poll drains the remainder.
		if remaining {
			if let Ok(mut w) = r.writer.lock() {
				let _ = w.write(&[1u8]);
			}
		}
		n as isize
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
		ep.rt.spawn(nb_acceptor(ep.ep.clone(), acc, readiness));
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
		Some(Box::into_raw(Box::new(PancakeIrohConn {
			rt: ep.rt.handle().clone(),
			conn: raw.conn,
			send: Mutex::new(Some(raw.send)),
			recv: Mutex::new(Some(raw.recv)),
			nb: OnceLock::new(),
			nb_tasks: OnceLock::new(),
		})))
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
			id: conn as usize,
			inbound: Mutex::new(Inbound::default()),
			outbound: Mutex::new(Outbound::default()),
			read_room: Notify::new(),
			write_work: Notify::new(),
		});
		if conn_ref.nb.set(nb.clone()).is_err() {
			return 0; // raced; the other set won, leave the streams to it
		}
		let reader = ep.rt.spawn(nb_reader(nb.clone(), recv));
		let writer = ep.rt.spawn(nb_writer(nb.clone(), send));
		let _ = conn_ref.nb_tasks.set((reader, writer));
		// The connection starts writable: the loop may flush as soon as it has
		// bytes to send.
		readiness.signal(conn as usize, EV_WRITABLE);
		0
	}));
	result.unwrap_or(-1)
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

/// Non-blocking write: enqueue all `len` bytes from `buf` for the writer task.
/// Returns `len` on success, -1 if the connection is closed, or
/// `PANCAKE_IROH_WOULD_BLOCK` (-2) when the outbound buffer is at its bound, the
/// loop re-arms on the next `EV_WRITABLE`. The connection must have been moved to
/// the readiness surface with `conn_set_nonblocking`. Borrows the handle.
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
		let mut out = nb.outbound.lock().unwrap();
		if out.closed {
			return -1;
		}
		if out.buf.len() >= NB_BUFFER_BOUND {
			return WOULD_BLOCK;
		}
		let src = unsafe { std::slice::from_raw_parts(buf, len) };
		out.buf.extend_from_slice(src);
		drop(out);
		nb.write_work.notify_one();
		len as isize
	}));
	result.unwrap_or(-1)
}

/// Close the endpoint without releasing its handle: a blocked
/// `pancake_iroh_sidecar_accept` returns null, subsequent dials fail, and queued
/// connection closes are delivered. Idempotent. Borrows the handle; the
/// handle stays valid until `pancake_iroh_sidecar_endpoint_free`.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_endpoint_close(ep: *mut PancakeIrohEndpoint) {
	let _ = catch_unwind(AssertUnwindSafe(|| {
		let ep = unsafe { &*ep };
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
		handle.rt.block_on(handle.ep.close());
		// Dropping the runtime outside an async context shuts it down cleanly.
		drop(handle);
	}));
}
