//! The iroh netlayer sidecar (ADR-0021).
//!
//! This staticlib wraps one iroh endpoint behind the narrow C ABI
//! declared in `include/glowcap_iroh_sidecar.h`, emitting
//! `libglowcap_iroh_sidecar.a`. Its only consumer
//! is the Zig sidecar owner, `src/net/transport/iroh/sidecar.zig`. Shape decisions:
//!
//! * Each endpoint owns its own tokio runtime behind the opaque handle, so a
//!   caller needs no async runtime of its own. Evented dial, accept, and stream
//!   I/O surface through one readiness fd. The explicit blocking resident keeps
//!   the few `_blocking` calls. The runtime's thread bill is explicit and
//!   bounded: two worker threads named `glowcap-iroh`.
//! * The caller chooses the endpoint's reachability when it is created, and
//!   nothing is on by default: `REACH_DIRECT` binds relay-less and lookup-less
//!   (dial by id plus explicit address hints), `REACH_DISCOVERY` adds the
//!   number-0 relays and DNS/pkarr discovery so a peer is dialable by id alone
//!   over the public internet, `REACH_DISCOVERY_NO_RELAY` keeps discovery but
//!   drops relays, and `REACH_LOCAL_DISCOVERY` is an in-process address book for
//!   tests and same-process embeddings. Enabling relays or a discovery service
//!   is always the host's explicit decision, never a hidden default.
//! * One bidirectional QUIC stream carries the whole OCapN session. QUIC bi
//!   streams are lazy, the acceptor cannot see the stream until the dialer
//!   writes, which OCapN guarantees, because the dialer sends `op:start-session`
//!   first.
//! * No panic crosses the FFI boundary: every entry point runs under
//!   `catch_unwind` and maps a panic to the function's error return.

mod admission;
mod conn;
mod connect;
mod constants_gen;
#[cfg(test)]
mod lifecycle_test;
mod nonblocking;

use connect::*;
use nonblocking::*;

use std::collections::{BTreeSet, HashMap};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::os::fd::AsRawFd;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::str::FromStr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock, mpsc};

use iroh::address_lookup::memory::MemoryLookup;
use iroh::endpoint::{ConnectError, Connection, ConnectionError, RecvStream, SendStream, presets};
use iroh::{Endpoint, EndpointAddr, EndpointId, SecretKey};
use tokio::sync::Notify;
use tokio::task::JoinHandle;

use glowcap_sidecar_common::{RuntimeOwner, TaskBarrier};

/// The shared readiness channel, drained into this sidecar's own record layout.
type Readiness = glowcap_sidecar_common::Readiness<GlowcapIrohReadyEvent>;

fn teardown_status<E>(f: impl FnOnce() -> Result<(), E>) -> i32 {
	match catch_unwind(AssertUnwindSafe(f)) {
		Ok(Ok(())) => 0,
		Ok(Err(_)) | Err(_) => -1,
	}
}

/// The ALPN both glowcap peers negotiate (ADR-0021).
const ALPN: &[u8] = b"ocapn/glowcap/1";

/// Upper bound on a single dial, discovery resolution plus relay/hole-punch
/// setup. A dial that cannot be established within this window terminates with
/// a timed-out code (the Zig resident maps it to `error.TimedOut`). Loopback and
/// in-process dials complete in
/// milliseconds, so this bounds only the public-discovery path, where it keeps a
/// failed dial from hanging a gate or a caller.
const CONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// The connection-level idle timeout when the caller names none. What the
/// setting is for is documented once, on the C ABI's `GlowcapIrohConfig`. This
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
/// the endpoint's remaining lifetime. Endpoint release waits the same bound for
/// its connection closes to drain.
const CLOSE_DRAIN_TIMEOUT: std::time::Duration = IDLE_TIMEOUT;

/// Worker threads for one endpoint's runtime when the caller names none. It is a
/// per-endpoint cost, so a process holding many endpoints, or one endpoint
/// holding many connections, should say what it wants instead.
const WORKER_THREADS: usize = 2;

/// One endpoint's configuration, passed by pointer rather than spread across
/// positional arguments.
///
/// Every layer above this one already carries a config object: the Zig
/// resident's `Resident.Config` and the C ABI's `GlowcapIrohConfig`. This is
/// the layer that was still counting arguments, and each new endpoint knob was
/// widening a signature that four call sites and an `extern fn` declaration had
/// to agree on. A struct means the next one is a field.
///
/// Zero means "no opinion" for both timeouts, which is what a caller that fills
/// only `reachability` gets from a zeroed struct.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct GlowcapIrohEndpointConfig {
	/// One of `GLOWCAP_IROH_REACH_*`. Mandatory. An unknown value is refused.
	pub reachability: u32,
	/// Stream-establishment deadline in milliseconds, 0 for the default.
	pub connect_timeout_ms: u64,
	/// How long a connection survives with nothing arriving on it, in
	/// milliseconds, 0 for the default. See `IDLE_TIMEOUT`.
	pub idle_timeout_ms: u64,
	/// Worker threads for this endpoint's runtime. 0 takes `WORKER_THREADS`.
	pub worker_threads: u32,
}

/// Reachability postures, chosen explicitly by the caller, with no default. A
/// glowcap peer never enables relays or a discovery service as a
/// hidden implementation detail. The host decides, in the open, how this
/// endpoint becomes reachable. These values mirror
/// `GLOWCAP_IROH_REACH_*` in `include/glowcap_iroh_sidecar.h` and the
/// `Reachability` enum the Zig resident exposes.
const REACH_DIRECT: u32 = 0;
const REACH_DISCOVERY: u32 = 1;
const REACH_DISCOVERY_NO_RELAY: u32 = 2;
const REACH_LOCAL_DISCOVERY: u32 = 3;

/// `conn_try_read` / `conn_try_write` return this when the operation cannot make
/// progress without blocking: no inbound bytes are buffered yet, or the outbound status-allow: pending state or quoted runtime label
/// buffer has no room. The loop yields the connection and re-arms it on the next
/// readiness event. Distinct from `0` (clean end of stream or zero-length write)
/// and `-1` (error). Mirrors `GLOWCAP_IROH_WOULD_BLOCK` in the header and the
/// Zig resident.
const WOULD_BLOCK: isize = -2;

/// Readiness event bits packed into `GlowcapIrohReadyEvent.events`. A single
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
/// The endpoint this dial was asked on is already closed: a local lifecycle
/// fault, permanent for this endpoint, and never a reason to retry.
const DIAL_CLOSED: i32 = 8;
/// The partner refused the connection during the QUIC or TLS handshake, or
/// this endpoint rejected it locally: a peer-refusal fault, not a path fault.
const DIAL_REFUSED: i32 = 9;

/// Bound on the text a failed dial keeps beside its code: iroh's own account
/// of the fault, which the code alone cannot carry (which relay refused, which
/// address stayed silent, the QUIC close reason). Mirrors
/// `GLOWCAP_IROH_SIDECAR_DIAL_TEXT_BYTES` in the header and `dial_text_bytes`
/// in the Zig resident, so a caller that sizes its buffer by the constant
/// never sees a truncated copy.
const DIAL_TEXT_BYTES: usize = 256;

/// The non-blocking inbound/outbound buffer bound, per connection and direction
/// (ADR-0019's back-pressure policy). A reader that fills the inbound buffer
/// stops reading the QUIC stream until the loop drains it, so a slow consumer
/// applies QUIC flow control to its partner rather than letting the sidecar
/// buffer without limit. A `conn_try_write` admits only the prefix that fits
/// under the outbound bound and returns `WOULD_BLOCK` only when no byte can fit.
/// One largest-admissible CapTP frame fits well within this, so steady traffic
/// never blocks on it.
const NB_BUFFER_BOUND: usize = 1 << 20;

/// The steady per-direction buffer capacity a connection retains once a burst
/// drains. Generated from `steady_outbound_bytes`, the Zig owner of the same
/// burst-frees-on-drain posture.
const NB_STEADY_BYTES: usize = constants_gen::NB_STEADY_BYTES;

/// Cap on one `read_chunk` segment in the reader task. The chunk is a zero-copy
/// borrow of the QUIC reassembly buffer, so the cap costs no memory. The reader
/// further limits every request to the queue's exact remaining budget, keeping
/// `NB_BUFFER_BOUND` an actual bound rather than a threshold with overshoot.
const READ_CHUNK_BYTES: usize = constants_gen::READ_CHUNK_BYTES;

/// Accepted loop connections retained by the sidecar before Zig claims them.
/// This mirrors the Zig backend's accept stash: both producer and consumer
/// queues have the same admission posture.
const ACCEPT_QUEUE_BOUND: usize = constants_gen::ACCEPT_QUEUE_BOUND;

/// Outbound dials retained as Tokio tasks or terminal results until the caller
/// consumes them. A caller controls request ids and completion consumption, so
/// this boundary must refuse admission rather than turn either behavior into an
/// unbounded endpoint-owned task/map queue.
const DIAL_ADMISSION_BOUND: usize = 32;

/// One drained readiness record. `subject` is zero for `EV_ACCEPT`, a caller
/// request id for `EV_CONNECT`, and otherwise a stable endpoint-scoped
/// connection id. `#[repr(C)]` keeps the layout in lockstep with
/// `glowcap_iroh_sidecar_ready_event` and the Zig resident's `ReadyEvent`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct GlowcapIrohReadyEvent {
	subject: usize,
	events: u32,
}

impl From<(usize, u32)> for GlowcapIrohReadyEvent {
	fn from((subject, events): (usize, u32)) -> Self {
		GlowcapIrohReadyEvent { subject, events }
	}
}

/// The process-shared address book backing `REACH_LOCAL_DISCOVERY`. Every
/// endpoint bound in that mode publishes its own `EndpointAddr` here and
/// resolves partners from it, so a dial by endpoint id alone, no relay, no
/// DNS, no caller-supplied address hints, succeeds inside one process. This is
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
			IpAddr::V4(ip) if ip.is_unspecified() => SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), addr.port()),
			IpAddr::V6(ip) if ip.is_unspecified() => SocketAddr::new(IpAddr::V6(Ipv6Addr::LOCALHOST), addr.port()),
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
/// scale surface (ADR-0019) is used on this endpoint. An endpoint driven only
/// through the blocking calls never allocates them.
pub struct GlowcapIrohEndpoint {
	/// The deadline every bi-stream establishment on this endpoint rides, the
	/// dial's `connect` + `open_bi` and each `accept_bi`, so a partner that
	/// stalls mid-handshake cannot park a thread forever. Configured per
	/// endpoint (`connect_timeout_ms`, 0 = the `CONNECT_TIMEOUT` default).
	connect_timeout: std::time::Duration,
	readiness: OnceLock<Arc<Readiness>>,
	accept: OnceLock<Arc<AcceptState>>,
	dials: OnceLock<Arc<DialState>>,
	/// Terminal ownership for non-blocking writers. Completed tasks retain no
	/// endpoint row. Release waits only on the active count and claims failure.
	writers: Arc<TaskBarrier>,
	next_conn_id: AtomicUsize,
	// Rust drops fields in declaration order. The endpoint, discovery services,
	// dial registry, and task barriers must all retire before their runtime.
	ep: Endpoint,
	rt: RuntimeOwner,
}

/// Opaque connection handle: one QUIC connection carrying one bidirectional
/// stream. `send` and `recv` are independently locked so the two directions
/// never serialize against each other. They are `Option` because
/// `conn_set_nonblocking` moves the streams out to the reader/writer tasks,
/// after which the blocking calls refuse (the connection is owned by the loop).
/// `nb` holds the non-blocking state once that transition happens.
pub struct GlowcapIrohConn {
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
	writers: Arc<TaskBarrier>,
}

/// Create an endpoint. `secret_seed32` is either null (generate a fresh random
/// endpoint key) or a pointer to 32 bytes of Ed25519 secret key material.
/// `reachability` selects how this endpoint becomes reachable and is mandatory,
/// one of `GLOWCAP_IROH_REACH_*`, with no implicit default. An unknown value
/// returns null. Returns an owned handle (release with
/// `glowcap_iroh_sidecar_endpoint_free`) or null on failure. Blocks until the
/// UDP sockets are bound.
///
/// # Safety
/// `config` must be readable. When non-null, `secret_seed32` must address 32
/// readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_iroh_sidecar_endpoint_new(
	secret_seed32: *const u8,
	config: *const GlowcapIrohEndpointConfig,
) -> *mut GlowcapIrohEndpoint {
	if config.is_null() {
		return std::ptr::null_mut();
	}
	// Safety: the contract requires a readable config when non-null.
	let GlowcapIrohEndpointConfig {
		reachability,
		connect_timeout_ms,
		idle_timeout_ms,
		worker_threads,
	} = unsafe { *config };
	let result = catch_unwind(AssertUnwindSafe(|| {
		let rt = RuntimeOwner::new(
			tokio::runtime::Builder::new_multi_thread()
				.worker_threads(if worker_threads == 0 {
					WORKER_THREADS
				} else {
					worker_threads as usize
				})
				.thread_name("glowcap-iroh")
				.enable_all()
				.build()
				.ok()?,
		);
		// The reachability posture is the whole choice here: `Minimal` binds
		// relay-less and lookup-less, `N0` adds the number-0 relays and DNS/pkarr
		// discovery, `N0DisableRelay` keeps discovery but drops relays, and the
		// local book is an in-process address exchange. The caller picked one.
		let mut builder = match reachability {
			REACH_DIRECT => Endpoint::builder(presets::Minimal),
			REACH_DISCOVERY => Endpoint::builder(presets::N0),
			REACH_DISCOVERY_NO_RELAY => Endpoint::builder(presets::N0DisableRelay),
			REACH_LOCAL_DISCOVERY => Endpoint::builder(presets::Minimal).address_lookup(local_book().clone()),
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
			// decision. An idle timeout only makes sense if packets are still
			// expected to arrive on a connection nobody is using, and that is
			// what a keep-alive provides. Exposing both would let a caller set
			// a timeout shorter than its own heartbeat and drop connections
			// whose peers are alive and answering.
			//
			// So the caller states the one thing it means, how fast a dead
			// peer should be noticed, and the heartbeat follows it: iroh's
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
		Some(Box::into_raw(Box::new(GlowcapIrohEndpoint {
			connect_timeout,
			readiness: OnceLock::new(),
			accept: OnceLock::new(),
			dials: OnceLock::new(),
			writers: Arc::new(TaskBarrier::new()),
			next_conn_id: AtomicUsize::new(1),
			ep,
			rt,
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

/// Write the endpoint's id, its Ed25519 public key, the dialable designator,
/// into `out` as lowercase hex (64 bytes; iroh's canonical string form, which
/// its parser accepts alongside base32). Returns the complete byte count and
/// copies only when `out_cap` is large enough. Borrows the handle. Writes no
/// terminator.
///
/// # Safety
/// `ep` must be live, and `out` must be writable for `out_cap` bytes when the
/// capacity is nonzero.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_iroh_sidecar_endpoint_node_id(
	ep: *const GlowcapIrohEndpoint,
	out: *mut u8,
	out_cap: usize,
) -> isize {
	let result = catch_unwind(AssertUnwindSafe(|| {
		// SAFETY: the `# Safety` contract requires `ep` to be a live endpoint handle from
		// `glowcap_iroh_sidecar_endpoint_new` that the caller does not free during the call; this function does not
		// check for null, so the contract is the only guard. The shared borrow ends with this closure.
		let ep = unsafe { &*ep };
		write_str(&ep.ep.id().to_string(), out, out_cap)
	}));
	result.unwrap_or(-1)
}

/// Write the endpoint's directly dialable socket addresses into `out` as a
/// comma-separated UTF-8 list (e.g. `127.0.0.1:5000,[::1]:5001`). Bound
/// wildcard addresses are reported as their loopback form, so the list is
/// dialable on the local host. Concretely discovered addresses are included
/// as-is. This is the hint string a partner passes to either connect surface.
/// Returns the complete byte count and copies only when `out_cap` is large
/// enough. Borrows the handle. Writes no terminator.
///
/// # Safety
/// `ep` must be live, and `out` must be writable for `out_cap` bytes when the
/// capacity is nonzero.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_iroh_sidecar_endpoint_direct_addrs(
	ep: *const GlowcapIrohEndpoint,
	out: *mut u8,
	out_cap: usize,
) -> isize {
	let result = catch_unwind(AssertUnwindSafe(|| {
		// SAFETY: as `glowcap_iroh_sidecar_endpoint_node_id` above, `ep` is the live endpoint handle the `# Safety`
		// contract requires, with no null check in this function; the shared borrow ends with this closure.
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

/// Close the endpoint without releasing its handle: an in-flight bounded accept
/// returns null, subsequent dials fail, and queued connection closes are
/// delivered. Idempotent. Borrows the handle. The handle stays valid until
/// `glowcap_iroh_sidecar_endpoint_free`.
///
/// # Safety
/// `ep` must be null or a live endpoint handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_iroh_sidecar_endpoint_close(ep: *mut GlowcapIrohEndpoint) {
	if ep.is_null() {
		return;
	}
	let _ = catch_unwind(AssertUnwindSafe(|| {
		// SAFETY: `ep` is non-null (checked above), and the caller's contract makes it a live endpoint handle
		// borrowed for this call; closing only cancels dials and spawns the endpoint close, leaving the handle valid.
		let ep = unsafe { &*ep };
		if let Some(dials) = ep.dials.get() {
			dials.cancel_all();
		}
		let endpoint = ep.ep.clone();
		drop(ep.rt.spawn(async move { endpoint.close().await }));
	}));
}

/// Release an endpoint handle. Blocks while iroh delivers queued connection
/// closes, for at most the close-drain bound, then shuts the runtime down. A
/// close no peer acknowledges in that time is not a failure. Free every
/// connection minted from this endpoint first.
///
/// # Safety
/// `ep` must be null or an owned endpoint handle not previously freed, and status-allow: ownership and operation ordering
/// every connection minted from it must already have been released.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_iroh_sidecar_endpoint_free(ep: *mut GlowcapIrohEndpoint) -> i32 {
	if ep.is_null() {
		return 0;
	}
	teardown_status(|| {
		// SAFETY: `ep` is non-null (checked above) and, per this function's `# Safety` contract, an owned endpoint
		// handle that `glowcap_iroh_sidecar_endpoint_new` boxed with `Box::into_raw` and that has not been freed, with
		// every connection minted from it already released; this takes back that one allocation and `ep` is not used
		// again.
		let handle = unsafe { Box::from_raw(ep) };
		if let Some(dials) = handle.dials.get() {
			dials.cancel_all();
		}
		let writer_result = handle.writers.wait();
		let endpoint = handle.ep.clone();
		let (closed_tx, closed_rx) = mpsc::sync_channel(1);
		drop(handle.rt.spawn(async move {
			endpoint.close().await;
			let _ = closed_tx.send(());
		}));
		// tolerant: a close that no peer acknowledges within the bound is the
		// peer's silence, not this teardown's failure. A peer that closed at the
		// same moment and then released its endpoint keeps our connection
		// draining until noq's backed-off probe timeout, and that peer learns
		// nothing more from waiting longer.
		let _ = closed_rx.recv_timeout(CLOSE_DRAIN_TIMEOUT);
		// RuntimeOwner is safe to drop even when this C call originated inside an
		// unrelated Tokio runtime.
		drop(handle);
		writer_result
	})
}

#[cfg(test)]
mod tests;
