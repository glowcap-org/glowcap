//! iroh transport for the async surface (the `iroh` feature).
//!
//! iroh's encrypted-QUIC netlayer links the Rust sidecar, which ADR-0055 keeps
//! out of the pure-Zig archives; it ships as its own optional companion library,
//! `libpancake_net_transport_iroh`, built with `zig build iroh-abi` (needs cargo). It exports
//! only the `pancake_iroh_*` family, so the `iroh` cargo feature links it
//! *alongside* the static core archives (core symbols come from there) and exposes a
//! dialer/listener here.
//!
//! The frame unit is identical to TCP's — one codec-self-delimited CapTP
//! message. Byte-fed iroh channels use [`IrohStream`], whose private
//! `IrohLoop` owns the sidecar readiness choreography for dial and explicit
//! Host-sharing paths. The default listener registers the same endpoint as a
//! resident with `driver_loop`; its generic listener lifecycle owns accept,
//! handshake, and session release.

use std::collections::HashMap;
use std::io;
use std::os::fd::{BorrowedFd, OwnedFd, RawFd};
use std::pin::Pin;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};

use tokio::io::unix::AsyncFd;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::{oneshot, Notify};
use tokio::task::JoinHandle;

use crate::abi_constants::{DISCOVERY_DIAL_MAX_ATTEMPTS, DISCOVERY_DIAL_RETRY_MS};
use crate::sys::iroh as ffi;
use crate::{sys, Error, Host, Reachability, Result, Session};

use ffi::{
	PancakeIrohConn, PancakeIrohNetlayer, PancakeIrohReadyEvent, PANCAKE_IROH_EV_ACCEPT,
	PANCAKE_IROH_EV_CLOSED, PANCAKE_IROH_EV_CONNECT, PANCAKE_IROH_EV_READABLE,
	PANCAKE_IROH_EV_WRITABLE,
};

// How many readiness records one `drain_ready` call pulls. When the fd signals,
// the loop drains in a batch and re-drains until a short count, so a queue deeper
// than the cap is never stranded.
const DRAIN_READY_CAP: usize = 64;

crate::error_slot::error_slot!(
	// Like the core `check`, but for `pancake_iroh_*` calls: snapshot the iroh
	// transport's own thread-local last-error rather than the unrelated
	// ocapn-family one. A `pancake_iroh_*` call that returns PANCAKE_ERR_IO
	// records its concrete cause in this slot.
	fn check_iroh;
	fn iroh_last_error;
	ffi::pancake_iroh_last_error
);

const RELEASE_OPEN: u8 = 0;
const RELEASE_RESERVED: u8 = 1;
const RELEASE_RUNNING: u8 = 2;
const RELEASE_DONE: u8 = 3;

type ReleaseFn = unsafe fn(usize);

// A release task is retained until its blocking call has completed. The
// reserved/running split lets a last-resort Drop fallback claim a queued task
// after Tokio starts shutting down: the task then observes the running claim
// and skips the native call, so release remains exactly once.
struct NetlayerRelease {
	phase: AtomicU8,
	task: Mutex<Option<JoinHandle<()>>>,
	notify: Notify,
	close_lock: tokio::sync::Mutex<()>,
}

impl NetlayerRelease {
	fn new() -> NetlayerRelease {
		NetlayerRelease {
			phase: AtomicU8::new(RELEASE_OPEN),
			task: Mutex::new(None),
			notify: Notify::new(),
			close_lock: tokio::sync::Mutex::new(()),
		}
	}

	fn start(self: &Arc<NetlayerRelease>, raw: usize, release: ReleaseFn) {
		// Store the JoinHandle before a waiter can take it, even if the blocking
		// task runs to completion immediately.
		let mut task_slot = self.task.lock().unwrap();
		if self
			.phase
			.compare_exchange(
				RELEASE_OPEN,
				RELEASE_RESERVED,
				Ordering::AcqRel,
				Ordering::Acquire,
			)
			.is_err()
		{
			return;
		}
		let state = Arc::clone(self);
		let task = tokio::task::spawn_blocking(move || {
			if state
				.phase
				.compare_exchange(
					RELEASE_RESERVED,
					RELEASE_RUNNING,
					Ordering::AcqRel,
					Ordering::Acquire,
				)
				.is_ok()
			{
				unsafe { release(raw) };
				state.phase.store(RELEASE_DONE, Ordering::Release);
				state.notify.notify_waiters();
			}
		});
		*task_slot = Some(task);
	}

	async fn wait(&self) -> Result<()> {
		// Join first when this owner retained the task. A panic or runtime
		// cancellation must surface as an error instead of leaving every waiter
		// asleep forever waiting for a DONE store the task never performed.
		let task = self.task.lock().unwrap().take();
		if let Some(task) = task {
			task.await
				.map_err(|_| Error::from_code(sys::ERR_INTERNAL))?;
		}
		loop {
			if self.phase.load(Ordering::Acquire) == RELEASE_DONE {
				return Ok(());
			}
			let notified = self.notify.notified();
			if self.phase.load(Ordering::Acquire) == RELEASE_DONE {
				return Ok(());
			}
			notified.await;
		}
	}

	fn fallback(&self, raw: usize, release: ReleaseFn) {
		loop {
			let phase = self.phase.load(Ordering::Acquire);
			if phase == RELEASE_DONE || phase == RELEASE_RUNNING {
				return;
			}
			if self
				.phase
				.compare_exchange(phase, RELEASE_RUNNING, Ordering::AcqRel, Ordering::Acquire)
				.is_ok()
			{
				unsafe { release(raw) };
				self.phase.store(RELEASE_DONE, Ordering::Release);
				self.notify.notify_waiters();
				return;
			}
		}
	}
}

unsafe fn release_native(raw: usize) {
	ffi::pancake_iroh_netlayer_release(raw as *mut PancakeIrohNetlayer);
}

// The raw netlayer handle is shared (behind an `Arc`) between the public
// `IrohNetlayer`/`IrohServer` and the readiness loop's dispatcher task. Explicit
// owners join that task before consuming the handle and awaiting release. Drop
// is only a last-resort fallback for cancellation/runtime shutdown; it releases
// synchronously after claiming the same state, never racing a queued release.
struct NetlayerRaw {
	raw: *mut PancakeIrohNetlayer,
	release: Arc<NetlayerRelease>,
}

// SAFETY: sharing `&NetlayerRaw` across threads only exposes reads of the raw
// pointer *value*, which is trivially safe. Concurrent *FFI use* of the endpoint
// behind it — the dispatcher's `drain_ready` on the reactor thread versus the
// public handle's accessors/`close` on a caller thread — is defined because the
// sidecar endpoint behind `pancake_iroh_netlayer_*` is internally synchronized:
// iroh's `Endpoint` is `Send + Sync` and the readiness queue is mutex-guarded.
// The `Arc` only keeps the handle alive and moves its release across threads.
unsafe impl Send for NetlayerRaw {}
unsafe impl Sync for NetlayerRaw {}

impl Drop for NetlayerRaw {
	fn drop(&mut self) {
		if tokio::runtime::Handle::try_current().is_ok() {
			// Drop cannot await, but it must not park a Tokio worker on the
			// sidecar's runtime join. Retain one blocking task when Tokio can own
			// it; outside a runtime, synchronous release is the final fallback.
			self.release.start(self.raw as usize, release_native);
		} else {
			self.release.fallback(self.raw as usize, release_native);
		}
	}
}

/// One iroh endpoint's configuration, field-for-field with the header's
/// `PancakeIrohConfig`, which documents what each setting means. `None` for a
/// timeout takes the transport's default.
///
/// `reachability` is mandatory, which is why this type has no `Default`:
/// enabling relays or a discovery service is always the caller's visible
/// choice. `connect_timeout_ms` bounds getting a connection up,
/// `idle_timeout_ms` bounds keeping one. Set `idle_timeout_ms` if you read a
/// live session as presence, because it is what ends a connection whose peer
/// was killed rather than closed.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct IrohConfig {
	pub reachability: Reachability,
	pub connect_timeout_ms: Option<u64>,
	pub idle_timeout_ms: Option<u64>,
	pub worker_threads: Option<u32>,
}

impl IrohConfig {
	/// A configuration with only the mandatory posture set, every timeout left
	/// to the transport.
	pub fn new(reachability: Reachability) -> IrohConfig {
		IrohConfig {
			reachability,
			connect_timeout_ms: None,
			idle_timeout_ms: None,
			worker_threads: None,
		}
	}

	/// How long a connection may go with nothing arriving on it before it is
	/// declared dead. See the type's own documentation for why this is the knob
	/// a presence-shaped application sets.
	pub fn with_idle_timeout_ms(mut self, ms: u64) -> IrohConfig {
		self.idle_timeout_ms = Some(ms);
		self
	}

	/// How long establishing a connection may take before it is abandoned.
	pub fn with_connect_timeout_ms(mut self, ms: u64) -> IrohConfig {
		self.connect_timeout_ms = Some(ms);
		self
	}

	/// Worker threads for this endpoint's runtime.
	pub fn with_worker_threads(mut self, threads: u32) -> IrohConfig {
		self.worker_threads = Some(threads);
		self
	}
}

/// A bound iroh QUIC endpoint plus the sidecar runtime driving it, the iroh
/// sibling of the TCP `Netlayer`. Dial with
/// [`IrohNetlayer::connect_owned`] or host with [`IrohServer`]. Call
/// [`IrohNetlayer::release`] after every connection minted from it is released;
/// Drop is only the last-resort fallback.
#[derive(Clone)]
pub struct IrohNetlayer {
	raw: Arc<NetlayerRaw>,
	reachability: Reachability,
}

// The driver owns the native callback context through its provider lease. The
// binding keeps only immutable facts needed to reject conflicting reuse and to
// publish the endpoint designator; it does not retain an endpoint owner here.
pub(crate) struct IrohLoopState {
	config: IrohConfig,
	node_id: String,
}

impl IrohLoopState {
	pub(crate) fn config(&self) -> IrohConfig {
		self.config
	}

	pub(crate) fn node_id(&self) -> &str {
		&self.node_id
	}
}

// Shuts a freshly-started loop down if the `connect_owned` future is dropped
// before the dial completes. `IrohLoop::run` never returns until `shutdown`, and
// `IrohLoop` has no `Drop`, so a cancelled dial would otherwise leak the endpoint
// (a live QUIC socket), the duped readiness fd, and the parked dispatcher task
// through the task's retained `Arc<IrohLoop>`. Disarmed the instant the dial
// succeeds and the loop moves into the returned `IrohStream` (whose `Drop` then
// owns the shutdown). Holds its own `Arc` clone so the loop can still move into
// the stream while the guard lives out the enclosing scope.
struct LoopGuard {
	iloop: Arc<IrohLoop>,
	armed: bool,
}

struct DialGuard {
	netlayer: Arc<NetlayerRaw>,
	request_id: usize,
	armed: bool,
}

impl Drop for DialGuard {
	fn drop(&mut self) {
		if self.armed {
			unsafe {
				ffi::pancake_iroh_netlayer_cancel_connect(self.netlayer.raw, self.request_id);
			}
		}
	}
}

impl Drop for LoopGuard {
	fn drop(&mut self) {
		if self.armed {
			self.iloop.shutdown();
		}
	}
}

impl IrohNetlayer {
	/// Bind an iroh endpoint with a fresh random Ed25519 key and the caller's
	/// chosen [`Reachability`], the mandatory posture deciding whether the
	/// endpoint uses relays or a discovery service. There is no default. Binds
	/// the endpoint and arms its readiness loop.
	pub async fn new(config: IrohConfig) -> Result<IrohNetlayer> {
		let mut seed = [0u8; 32];
		getrandom::fill(&mut seed).expect("the OS RNG provides an iroh endpoint seed");
		IrohNetlayer::from_seed(config, seed).await
	}

	/// Bind an iroh endpoint whose Ed25519 identity is reconstructed from
	/// `seed` — the same durable identity a [`Host`](crate::Host) must use so
	/// designator and endpoint id stay one value (ADR-0075). CapTP session
	/// signing keys still come from the Host's fresh session-key root
	/// (ADR-0097).
	pub async fn from_seed(config: IrohConfig, seed: [u8; 32]) -> Result<IrohNetlayer> {
		tokio::task::spawn_blocking(move || IrohNetlayer::from_seed_blocking(config, &seed))
			.await
			.map_err(|_| Error::from_code(sys::ERR_INTERNAL))?
	}

	fn from_seed_blocking(config: IrohConfig, seed: &[u8; 32]) -> Result<IrohNetlayer> {
		let mut raw: *mut PancakeIrohNetlayer = core::ptr::null_mut();
		// `..Default::default()` zero-fills the rest, and 0 is the built-in
		// default for every timeout — the header's zero-init contract.
		let raw_config = ffi::PancakeIrohConfig {
			reachability: config.reachability as u32,
			connect_timeout_ms: config.connect_timeout_ms.unwrap_or(0),
			idle_timeout_ms: config.idle_timeout_ms.unwrap_or(0),
			worker_threads: config.worker_threads.unwrap_or(0),
		};
		check_iroh(unsafe {
			ffi::pancake_iroh_netlayer_new(seed.as_ptr(), seed.len(), &raw_config, &mut raw)
		})?;
		Ok(IrohNetlayer {
			raw: Arc::new(NetlayerRaw {
				raw,
				release: Arc::new(NetlayerRelease::new()),
			}),
			reachability: config.reachability,
		})
	}

	/// This endpoint's id, its Ed25519 public key as lowercase hex, the dialable
	/// designator and the URI host.
	pub fn node_id(&self) -> Result<String> {
		let mut buf = [0u8; 64];
		let mut len: usize = 0;
		check_iroh(unsafe {
			ffi::pancake_iroh_netlayer_node_id(self.raw.raw, buf.as_mut_ptr(), buf.len(), &mut len)
		})?;
		Ok(String::from_utf8_lossy(&buf[..len]).into_owned())
	}

	/// Return this endpoint's archive-owned provider package.
	pub fn transport_provider(&self) -> Result<crate::driver_loop::TransportProvider<'_>> {
		let mut package: crate::sys::driver::PancakeTransportProvider =
			unsafe { core::mem::zeroed() };
		check_iroh(unsafe { ffi::pancake_iroh_transport_provider(self.raw.raw, &mut package) })?;
		Ok(crate::driver_loop::TransportProvider {
			package,
			_owner: core::marker::PhantomData,
		})
	}

	/// This endpoint's comma-separated direct socket addresses, the hint string a
	/// partner passes to dial it relay-less.
	pub fn direct_addresses(&self) -> Result<String> {
		direct_addresses(self.raw.raw)
	}

	/// Close the endpoint without releasing the handle: later dials fail and the
	/// readiness loop winds down. Idempotent, the shutdown lever a dropped dialer
	/// or server pulls.
	pub async fn close(&self) -> Result<()> {
		let raw = Arc::clone(&self.raw);
		tokio::task::spawn_blocking(move || unsafe { ffi::pancake_iroh_netlayer_close(raw.raw) })
			.await
			.map_err(|_| Error::from_code(sys::ERR_INTERNAL))
	}

	/// Close and release this endpoint, joining the one native release task.
	///
	/// This consumes the netlayer so no caller can use its raw handle after the
	/// release barrier completes. Call it after every connection and readiness
	/// loop borrowing this endpoint has been joined. Dropping instead is a
	/// cancellation/runtime-shutdown fallback and may block synchronously.
	pub async fn release(self) -> Result<()> {
		self.release_shared().await
	}

	async fn release_shared(&self) -> Result<()> {
		let _close_guard = self.raw.release.close_lock.lock().await;
		if self.raw.release.phase.load(Ordering::Acquire) == RELEASE_DONE {
			return self.raw.release.wait().await;
		}
		let close_result = self.close().await;
		self.raw
			.release
			.start(self.raw.raw as usize, release_native);
		let release_result = self.raw.release.wait().await;
		close_result.and(release_result)
	}

	/// Dial a partner by endpoint id and direct-address hints over the
	/// event-driven loop surface (ADR-0057), returning the byte stream that
	/// carries the OCapN session. Dial establishment and frame I/O are both
	/// driven by the stream's readiness loop. The returned stream owns this netlayer's
	/// lifetime (an ephemeral dialing endpoint released with the connection).
	pub async fn connect_owned(self, node_id: &str, direct_addresses: &str) -> Result<IrohStream> {
		let iloop = IrohLoop::start(Arc::clone(&self.raw))?;
		// If this future is dropped (cancelled) while the dial is awaiting, the
		// guard's `Drop` shuts the loop down so the dispatcher task releases its
		// endpoint rather than leaking it. The `?` below routes an early dial
		// failure through the same shutdown, subsuming the old explicit error arm.
		let mut guard = LoopGuard {
			iloop: Arc::clone(&iloop),
			armed: true,
		};
		// A posture that resolves by id through a propagating discovery service
		// (`Discovery` and `DiscoveryNoRelay`) can fail a dial-by-id with "no
		// addressing information" until the exporter's pkarr record propagates
		// (seconds, variable), so retry the dial on a bounded budget; every other
		// posture dials once (Direct's addresses are in hand, LocalDiscovery
		// resolves instantly). Mirrors the TS `dialResolving` and the Zig
		// `iroh-reachability` driver.
		let conn = dial_resolving(
			&iloop,
			node_id,
			direct_addresses,
			matches!(
				self.reachability,
				Reachability::Discovery | Reachability::DiscoveryNoRelay
			),
		)
		.await?;
		// Dial succeeded: ownership of the loop moves into the returned stream,
		// whose `Drop` now owns the shutdown, so disarm the cancel guard.
		guard.armed = false;
		iloop.register(conn);
		Ok(IrohStream::new(
			conn as *mut PancakeIrohConn,
			iloop,
			Some(self),
			true,
		))
	}
}

fn direct_addresses(raw: *mut PancakeIrohNetlayer) -> Result<String> {
	// The endpoint with no direct addresses writes zero bytes; a buffer too
	// small is ERR_BUFFER_TOO_SMALL, so grow until it fits.
	let mut cap = 256usize;
	loop {
		let mut buf = vec![0u8; cap];
		let mut len: usize = 0;
		let code = unsafe {
			ffi::pancake_iroh_netlayer_direct_addrs(raw, buf.as_mut_ptr(), buf.len(), &mut len)
		};
		if code == sys::ERR_BUFFER_TOO_SMALL && cap < 64 * 1024 {
			cap *= 4;
			continue;
		}
		check_iroh(code)?;
		return Ok(String::from_utf8_lossy(&buf[..len]).into_owned());
	}
}

/// Attach the Host's one configured iroh endpoint to its native loop. The
/// endpoint identity comes from the Host, while the native driver decides
/// whether the provider name is already occupied.
pub(crate) async fn ensure_loop_provider(
	host: &Rc<crate::host::HostShared>,
	lp: &Rc<crate::driver_loop::LoopShared>,
	config: IrohConfig,
) -> Result<String> {
	host.guard_open()?;
	if let Some(bound) = host.iroh_state_config() {
		if bound != config {
			return Err(Error::with_detail(
				sys::ERR_INVALID_ARGUMENT,
				"the Host already has an iroh endpoint with incompatible configuration".to_string(),
			));
		}
		return host
			.iroh_state_node_id()
			.ok_or_else(|| Error::from_code(sys::ERR_INTERNAL));
	}

	let netlayer = IrohNetlayer::from_seed(config, host.durable_seed()).await?;
	let node_id = netlayer.node_id()?;
	lp.add_provider(netlayer.transport_provider()?)?;
	host.install_iroh_state(IrohLoopState {
		config,
		node_id: node_id.clone(),
	});
	Ok(node_id)
}

pub(crate) fn reachability_from_plan(reach_kind: u32, reach_value: u32) -> Reachability {
	if reach_kind == sys::DIAL_REACH_DIRECT {
		return Reachability::Direct;
	}
	match reach_value {
		v if v == Reachability::Direct as u32 => Reachability::Direct,
		v if v == Reachability::Discovery as u32 => Reachability::Discovery,
		v if v == Reachability::DiscoveryNoRelay as u32 => Reachability::DiscoveryNoRelay,
		v if v == Reachability::LocalDiscovery as u32 => Reachability::LocalDiscovery,
		_ => unreachable!("EXPLICIT reach_value is a Reachability discriminant"),
	}
}

// Discovery-posture dial retry (ADR-0082): lockstep with `PANCAKE_DISCOVERY_DIAL_*`.
// Only transient dial faults (projected as `ERR_IO`) are retried; permanent
// faults (`InvalidArgument`, `Internal`, …) surface immediately.
async fn dial_resolving(
	iloop: &Arc<IrohLoop>,
	node_id: &str,
	hints: &str,
	retry: bool,
) -> Result<usize> {
	let mut attempt: u32 = 1;
	loop {
		match iloop.dial(node_id, hints).await {
			Ok(conn) => return Ok(conn),
			Err(e) => {
				if e.kind() != crate::ErrorKind::Io
					|| !retry || attempt >= DISCOVERY_DIAL_MAX_ATTEMPTS as u32
				{
					return Err(e);
				}
			}
		}
		attempt += 1;
		tokio::time::sleep(std::time::Duration::from_millis(
			DISCOVERY_DIAL_RETRY_MS as u64,
		))
		.await;
	}
}

// One iroh connection pointer, released exactly once — when the owning
// `IrohStream` drops. No sidecar call ever parks on the connection (the loop's
// only blocking call touches the endpoint), so releasing it never races a parked
// read — the teardown hazard the thread-per-connection path had.
struct ConnPtr(*mut PancakeIrohConn);

// SAFETY: `Send` is required — an `IrohStream` moves between threads (the relay
// pumps one inside `tokio::spawn` tasks on a multithreaded runtime), so
// `pancake_iroh_conn_try_read`/`try_write` run on whichever thread polls it and
// `Drop`'s `pancake_iroh_conn_release` on whichever thread drops it, not the
// thread that dialed. That FFI use is defined because the sidecar connection is
// internally synchronized (mutex-guarded stream state over iroh's `Send + Sync`
// connection), and the pointer is single-owner (one `IrohStream` field), so the
// release runs exactly once. Not `Sync`: no `&ConnPtr` is ever shared across
// threads — the loop addresses the connection by its `key: usize`, never
// through this pointer.
unsafe impl Send for ConnPtr {}

impl Drop for ConnPtr {
	fn drop(&mut self) {
		unsafe { ffi::pancake_iroh_conn_release(self.0) };
	}
}

// Per-connection readiness state. A loop connection is single-owner (one task
// drives it), so at most one task waits to read and one to write; a `*_ready`
// flag holds an edge that arrived before its waiter so no wakeup is lost.
#[derive(Default)]
struct ConnSlot {
	read_waker: Option<Waker>,
	write_waker: Option<Waker>,
	readable: bool,
	writable: bool,
	closed: bool,
}

#[derive(Default)]
struct LoopState {
	conns: HashMap<usize, ConnSlot>,
	dials: HashMap<usize, oneshot::Sender<Result<usize>>>,
	accept_waker: Option<Waker>,
	accept_pending: usize,
	closed: bool,
}

/// The per-netlayer readiness dispatcher for the iroh loop surface (ADR-0057).
///
/// It registers the netlayer's single readiness fd with tokio's reactor (an
/// [`AsyncFd`] over a dup of the fd) and, when the fd signals, drains the pending
/// readiness records and wakes the task (a `poll_read`/`poll_write`, or an
/// accept) waiting on each. Everything runs on one reactor task — no thread per
/// connection — and because the drain touches only the endpoint, never a
/// per-connection buffer, a connection can be released at any time without racing
/// a read. A requested shutdown wakes every waiter; explicit owners join the
/// task before releasing the endpoint, so the drain can never touch a freed
/// endpoint. This is the Rust
/// sibling of the Deno binding's `IrohLoop` and Zig's
/// `completion.Loop(iroh.Backend)` + `driver.Bridge` + `driver_core.Host`:
/// one reactor multiplexes many connections.
pub(crate) struct IrohLoop {
	netlayer: Arc<NetlayerRaw>,
	state: Mutex<LoopState>,
	task: Mutex<Option<tokio::task::JoinHandle<()>>>,
	stop: AtomicBool,
	next_request: AtomicUsize,
	notify: Notify,
}

impl IrohLoop {
	/// Register the netlayer's readiness fd with the reactor and spawn the single
	/// dispatcher task. The loop is already armed (the netlayer arms it at
	/// construction), so this only stands up the reactor side.
	fn start(netlayer: Arc<NetlayerRaw>) -> Result<Arc<IrohLoop>> {
		let raw_fd: RawFd = unsafe { ffi::pancake_iroh_netlayer_readiness_fd(netlayer.raw) };
		if raw_fd < 0 {
			return Err(Error::with_transport_detail(sys::ERR_IO, iroh_last_error()));
		}
		// Dup the borrowed fd so the `AsyncFd` owns and closes its own copy on
		// drop, never the netlayer's fd. The dup shares the same socket, so its
		// readiness tracks the original and `drain_ready` (which reads the
		// original) clears both.
		let owned: OwnedFd = unsafe { BorrowedFd::borrow_raw(raw_fd) }
			.try_clone_to_owned()
			.map_err(|_| Error::from_code(sys::ERR_IO))?;
		let iloop = Arc::new(IrohLoop {
			netlayer,
			state: Mutex::new(LoopState::default()),
			task: Mutex::new(None),
			stop: AtomicBool::new(false),
			next_request: AtomicUsize::new(1),
			notify: Notify::new(),
		});
		let runner = Arc::clone(&iloop);
		let handle = tokio::spawn(async move {
			match AsyncFd::new(owned) {
				Ok(afd) => runner.run(afd).await,
				Err(_) => runner.wake_all_closed(),
			}
		});
		*iloop.task.lock().unwrap() = Some(handle);
		Ok(iloop)
	}

	fn register(&self, conn: usize) {
		let key = unsafe { ffi::pancake_iroh_conn_id(conn as *mut PancakeIrohConn) };
		self.state
			.lock()
			.unwrap()
			.conns
			.insert(key, ConnSlot::default());
	}

	fn unregister(&self, key: usize) {
		let wakers = {
			let mut st = self.state.lock().unwrap();
			remove_conn_wakers(&mut st, key)
		};
		for w in wakers {
			w.wake();
		}
	}

	async fn dial(&self, node_id: &str, hints: &str) -> Result<usize> {
		let request_id = self
			.next_request
			.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |next| {
				next.checked_add(1)
			})
			.map_err(|_| Error::from_code(sys::ERR_INTERNAL))?;
		let (sender, receiver) = oneshot::channel();
		self.state.lock().unwrap().dials.insert(request_id, sender);
		let rc = unsafe {
			ffi::pancake_iroh_netlayer_start_connect(
				self.netlayer.raw,
				request_id,
				node_id.as_ptr(),
				node_id.len(),
				hints.as_ptr(),
				hints.len(),
			)
		};
		if rc != sys::OK {
			self.state.lock().unwrap().dials.remove(&request_id);
			return Err(Error::with_transport_detail(rc, iroh_last_error()));
		}
		let mut guard = DialGuard {
			netlayer: Arc::clone(&self.netlayer),
			request_id,
			armed: true,
		};
		let result = receiver
			.await
			.unwrap_or_else(|_| Err(Error::from_code(sys::ERR_CLOSED)));
		guard.armed = false;
		result
	}

	// The dispatcher task: park on the readiness fd, and on each wake drain the
	// queue and route records to their waiters. The drain touches the netlayer
	// (`Arc`-kept-alive), never a per-connection buffer.
	async fn run(self: Arc<Self>, afd: AsyncFd<OwnedFd>) {
		loop {
			if self.stop.load(Ordering::Acquire) {
				break;
			}
			tokio::select! {
				biased;
				_ = self.notify.notified() => continue, // shutdown asked; re-check stop
				guard = afd.readable() => match guard {
					Ok(mut g) => {
						// Clear the reactor's readiness BEFORE draining. The other
						// order loses an edge: a record and its fd wakeup landing
						// between the drain and the clear are cleared away, and —
						// edge-triggered, with no successor record coming — the
						// final SETTLE strands. Cleared first, a record landing
						// mid-drain re-arms the fd, and the worst case is one
						// spurious wake whose drain reads short. Then drain until
						// a short count.
						g.clear_ready();
						self.drain();
					}
					Err(_) => break,
				},
			}
		}
		self.wake_all_closed();
	}

	// Drain the ready-queue in batches until a short count, routing each record
	// to its waiter (collected, woken after the lock is released).
	fn drain(&self) {
		let nl = self.netlayer.raw;
		let mut buf = [PancakeIrohReadyEvent {
			subject: 0,
			events: 0,
		}; DRAIN_READY_CAP];
		loop {
			let mut count: usize = 0;
			let rc = unsafe {
				ffi::pancake_iroh_netlayer_drain_ready(
					nl,
					buf.as_mut_ptr(),
					DRAIN_READY_CAP,
					&mut count,
				)
			};
			if rc != sys::OK || count == 0 {
				break;
			}
			let mut wakers: Vec<Waker> = Vec::new();
			for ev in buf.iter().take(count) {
				if ev.events & PANCAKE_IROH_EV_CONNECT != 0 {
					let mut conn: *mut PancakeIrohConn = core::ptr::null_mut();
					let rc = unsafe {
						ffi::pancake_iroh_netlayer_finish_connect(nl, ev.subject, &mut conn)
					};
					let result = if rc == sys::OK {
						Ok(conn as usize)
					} else {
						Err(Error::with_transport_detail(rc, iroh_last_error()))
					};
					if let Some(sender) = self.state.lock().unwrap().dials.remove(&ev.subject) {
						// A dropped dial future leaves the sender in the map until
						// this sole terminal event retires it. If delivery finds
						// the receiver gone, reclaim a successful connection here.
						if let Err(Ok(abandoned_conn)) = sender.send(result) {
							unsafe {
								ffi::pancake_iroh_conn_release(
									abandoned_conn as *mut PancakeIrohConn,
								)
							};
						}
					} else if rc == sys::OK {
						unsafe { ffi::pancake_iroh_conn_release(conn) };
					}
					continue;
				}
				let mut st = self.state.lock().unwrap();
				dispatch(&mut st, ev.subject, ev.events, &mut wakers);
			}
			for w in wakers {
				w.wake();
			}
			if count < DRAIN_READY_CAP {
				break;
			}
		}
	}

	fn wake_all_closed(&self) {
		let mut wakers: Vec<Waker> = Vec::new();
		let mut dials = Vec::new();
		{
			let mut st = self.state.lock().unwrap();
			st.closed = true;
			if let Some(w) = st.accept_waker.take() {
				wakers.push(w);
			}
			for slot in st.conns.values_mut() {
				slot.closed = true;
				wakers.extend(slot.read_waker.take());
				wakers.extend(slot.write_waker.take());
			}
			dials.extend(st.dials.drain().map(|(_, sender)| sender));
		}
		for sender in dials {
			let _ = sender.send(Err(Error::from_code(sys::ERR_CLOSED)));
		}
		for w in wakers {
			w.wake();
		}
	}

	/// Request loop shutdown and wake every waiter so parked pumps unwind.
	/// Explicit owners subsequently join the dispatcher; destructor paths use
	/// `shutdown` to abort it as a backstop. Aborting only takes effect at an
	/// await point, never mid-`drain`, and the netlayer's `Arc` outlives the task,
	/// so a freed endpoint is never drained.
	fn request_shutdown(&self) {
		self.stop.store(true, Ordering::Release);
		let requests: Vec<usize> = self.state.lock().unwrap().dials.keys().copied().collect();
		for request_id in requests {
			unsafe {
				ffi::pancake_iroh_netlayer_cancel_connect(self.netlayer.raw, request_id);
			}
		}
		self.wake_all_closed();
		self.notify.notify_waiters();
	}

	/// Request shutdown and join the dispatcher. Explicit owners use this
	/// barrier before releasing the endpoint; Drop uses `shutdown` below as a
	/// last resort because it cannot await.
	async fn shutdown_and_join(&self) -> Result<()> {
		self.request_shutdown();
		// Take the handle in its own statement so the mutex guard drops
		// before the await: a guard held across it makes the future !Send,
		// and the close registration runs this on a multi-thread runtime.
		let handle = self.task.lock().unwrap().take();
		if let Some(h) = handle {
			h.await.map_err(|_| Error::from_code(sys::ERR_INTERNAL))?;
		}
		Ok(())
	}

	/// Request shutdown and abort the dispatcher when no async barrier is
	/// available. This is only for cancellation/destructor paths.
	fn shutdown(&self) {
		self.request_shutdown();
		if let Some(h) = self.task.lock().unwrap().take() {
			h.abort();
		}
	}
}

fn remove_conn_wakers(st: &mut LoopState, key: usize) -> Vec<Waker> {
	let mut wakers = Vec::new();
	if let Some(mut slot) = st.conns.remove(&key) {
		wakers.extend(slot.read_waker.take());
		wakers.extend(slot.write_waker.take());
	}
	wakers
}

// Route one readiness record to its waiter (collected, woken after the lock is
// released). An accept record carries a null connection.
fn dispatch(st: &mut LoopState, conn_key: usize, events: u32, wakers: &mut Vec<Waker>) {
	if events & PANCAKE_IROH_EV_ACCEPT != 0 {
		// Record the pending accept first, then wake the byte-fed channel waiter;
		// the count survives a wake that races waiter registration.
		st.accept_pending += 1;
		if let Some(w) = st.accept_waker.take() {
			wakers.push(w);
		}
		return;
	}
	if let Some(slot) = st.conns.get_mut(&conn_key) {
		if events & PANCAKE_IROH_EV_CLOSED != 0 {
			slot.closed = true;
		}
		if events & (PANCAKE_IROH_EV_READABLE | PANCAKE_IROH_EV_CLOSED) != 0 {
			slot.readable = true;
			wakers.extend(slot.read_waker.take());
		}
		if events & (PANCAKE_IROH_EV_WRITABLE | PANCAKE_IROH_EV_CLOSED) != 0 {
			slot.writable = true;
			wakers.extend(slot.write_waker.take());
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::sync::Arc;
	use std::task::Wake;

	struct CountWake(Arc<AtomicUsize>);

	impl Wake for CountWake {
		fn wake(self: Arc<Self>) {
			self.0.fetch_add(1, Ordering::Relaxed);
		}
	}

	fn count_waker(count: &Arc<AtomicUsize>) -> Waker {
		Waker::from(Arc::new(CountWake(Arc::clone(count))))
	}

	static RELEASE_COUNT: AtomicUsize = AtomicUsize::new(0);

	unsafe fn count_release(_raw: usize) {
		RELEASE_COUNT.fetch_add(1, Ordering::SeqCst);
	}

	unsafe fn panic_release(_raw: usize) {
		panic!("release failed");
	}

	#[tokio::test]
	async fn netlayer_release_waits_and_claims_once() {
		RELEASE_COUNT.store(0, Ordering::SeqCst);
		let release = Arc::new(NetlayerRelease::new());
		release.start(0, count_release);
		release.start(0, count_release);
		release.wait().await.unwrap();
		release.wait().await.unwrap();
		assert_eq!(RELEASE_COUNT.load(Ordering::SeqCst), 1);

		let fallback = Arc::new(NetlayerRelease::new());
		fallback.phase.store(RELEASE_RESERVED, Ordering::Release);
		fallback.fallback(0, count_release);
		fallback.wait().await.unwrap();
		assert_eq!(RELEASE_COUNT.load(Ordering::SeqCst), 2);

		let panicked = Arc::new(NetlayerRelease::new());
		panicked.start(0, panic_release);
		assert!(panicked.wait().await.is_err());
	}

	#[test]
	fn unregister_wakes_read_and_write_waiters() {
		let count = Arc::new(AtomicUsize::new(0));
		let mut state = LoopState::default();
		state.conns.insert(
			7,
			ConnSlot {
				read_waker: Some(count_waker(&count)),
				write_waker: Some(count_waker(&count)),
				..ConnSlot::default()
			},
		);

		for w in remove_conn_wakers(&mut state, 7) {
			w.wake();
		}

		assert_eq!(count.load(Ordering::Relaxed), 2);
		assert!(!state.conns.contains_key(&7));
	}
}

/// A byte stream over one iroh QUIC connection: the iroh sibling of a
/// `TcpStream` for the [`Session`] driver. Inbound bytes
/// come from the sidecar's non-blocking `try_read`; the peer re-frames them.
/// Outbound bytes go through `try_write`, re-arming on the next writable record
/// when the sidecar buffer is full. Its readiness loop, not a parked blocking
/// read, decides when bytes move. `close().await` is the explicit teardown
/// barrier: a dialer (`owns_loop`) joins its loop and releases its ephemeral
/// endpoint; an accepted stream leaves the server's loop and releases its
/// connection. Dropping is only the last-resort fallback.
pub struct IrohStream {
	conn: Option<ConnPtr>,
	key: usize,
	registered: bool,
	iloop: Arc<IrohLoop>,
	owns_loop: bool,
	// A dialer's ephemeral endpoint, released after this stream's loop and
	// connection are torn down.
	owned_netlayer: Option<IrohNetlayer>,
}

impl IrohStream {
	/// The far end's node id, as QUIC proved it: this connection completed only
	/// because the peer held the secret for this key. `None` when the
	/// connection is gone or the handshake proved nothing.
	///
	/// This is the fact a session is otherwise missing. pancake cannot see it —
	/// it did not open this connection — so whoever did passes it on with
	/// [`Session::bind_verified_channel_key`], which the accept and dial paths
	/// below do for every session this module establishes.
	fn remote_node_id(&self) -> Option<String> {
		let mut buf = [0u8; 64];
		let mut len: usize = 0;
		let code = unsafe {
			ffi::pancake_iroh_conn_remote_node_id(
				self.conn.as_ref().expect("live iroh stream").0,
				buf.as_mut_ptr(),
				buf.len(),
				&mut len,
			)
		};
		if code != crate::abi_constants::OK {
			return None;
		}
		Some(String::from_utf8_lossy(&buf[..len]).into_owned())
	}

	fn new(
		conn: *mut PancakeIrohConn,
		iloop: Arc<IrohLoop>,
		owned_netlayer: Option<IrohNetlayer>,
		owns_loop: bool,
	) -> IrohStream {
		let key = unsafe { ffi::pancake_iroh_conn_id(conn) };
		IrohStream {
			conn: Some(ConnPtr(conn)),
			key,
			registered: true,
			iloop,
			owns_loop,
			owned_netlayer,
		}
	}

	/// Dial an iroh partner by endpoint id and direct-address hints, returning the
	/// byte stream the [`Session`] driver carries the
	/// session over. The local endpoint is ephemeral, created with the caller's
	/// chosen [`Reachability`] (no default), and released with the stream.
	pub async fn connect(
		node_id: &str,
		direct_addresses: &str,
		reachability: Reachability,
	) -> Result<IrohStream> {
		let netlayer = IrohNetlayer::new(IrohConfig::new(reachability)).await?;
		netlayer.connect_owned(node_id, direct_addresses).await
	}

	/// Tear down this stream and, for a dialer, its private endpoint. The
	/// readiness loop is joined before the connection is released, and the
	/// endpoint release task is awaited before this future completes.
	pub async fn close(self) -> Result<()> {
		let mut this = self;
		let conn = this.conn.take();
		let key = this.key;
		let iloop = Arc::clone(&this.iloop);
		let owns_loop = this.owns_loop;
		let owned_netlayer = this.owned_netlayer.take();

		let loop_result = if owns_loop {
			iloop.shutdown_and_join().await
		} else {
			Ok(())
		};
		if this.registered {
			iloop.unregister(key);
			this.registered = false;
		}
		// The connection must be gone before an owned endpoint can be released.
		drop(conn);
		let release_result = match owned_netlayer {
			Some(netlayer) => netlayer.release().await,
			None => Ok(()),
		};
		loop_result.and(release_result)
	}
}

impl Drop for IrohStream {
	fn drop(&mut self) {
		if self.owns_loop {
			// The dialer owns the loop and netlayer: stop the dispatcher so it
			// wakes its waiters and drops its netlayer `Arc`. The endpoint is
			// released once both this stream and the task have dropped their Arc.
			self.iloop.shutdown();
		}
		// Remove the routing entry on every path so an endpoint teardown can wait
		// for the last connection, including a dialer's private loop slot.
		if self.registered {
			self.iloop.unregister(self.key);
			self.registered = false;
		}
		drop(self.conn.take());
		// Leave the fields to Rust's declaration-order drop: ConnPtr is released
		// before the owned endpoint Arc, so the fallback cannot release an
		// endpoint while its connection is still live.
	}
}

impl AsyncRead for IrohStream {
	fn poll_read(
		self: Pin<&mut Self>,
		cx: &mut Context<'_>,
		buf: &mut ReadBuf<'_>,
	) -> Poll<io::Result<()>> {
		let me = self.get_mut();
		loop {
			let dst = buf.initialize_unfilled();
			if dst.is_empty() {
				return Poll::Ready(Ok(())); // the caller's buffer is full
			}
			let mut count: usize = 0;
			let rc = unsafe {
				ffi::pancake_iroh_conn_try_read(
					me.conn.as_ref().expect("live iroh stream").0,
					dst.as_mut_ptr(),
					dst.len(),
					&mut count,
				)
			};
			if rc == sys::WOULD_BLOCK {
				// Nothing buffered yet: park on this connection's readiness. A
				// missing/closed slot means the connection was torn down, a clean
				// EOF (zero bytes filled).
				let mut st = me.iloop.state.lock().unwrap();
				match st.conns.get_mut(&me.key) {
					None => return Poll::Ready(Ok(())),
					Some(slot) if slot.closed => return Poll::Ready(Ok(())),
					Some(slot) if slot.readable => {
						slot.readable = false;
						continue; // an edge arrived first; re-read before parking
					}
					Some(slot) => {
						slot.read_waker = Some(cx.waker().clone());
						return Poll::Pending;
					}
				}
			}
			if rc == sys::ERR_CLOSED {
				return Poll::Ready(Ok(())); // clean end of stream
			}
			if rc != sys::OK {
				return Poll::Ready(Err(io::Error::other(format!(
					"iroh try_read failed (code {rc})"
				))));
			}
			buf.advance(count);
			return Poll::Ready(Ok(()));
		}
	}
}

impl AsyncWrite for IrohStream {
	fn poll_write(
		self: Pin<&mut Self>,
		cx: &mut Context<'_>,
		src: &[u8],
	) -> Poll<io::Result<usize>> {
		let me = self.get_mut();
		if src.is_empty() {
			return Poll::Ready(Ok(0));
		}
		loop {
			let mut count: usize = 0;
			let rc = unsafe {
				ffi::pancake_iroh_conn_try_write(
					me.conn.as_ref().expect("live iroh stream").0,
					src.as_ptr(),
					src.len(),
					&mut count,
				)
			};
			if rc == sys::WOULD_BLOCK {
				// No byte fit: park on writability and retry this slice after the
				// next writable record.
				let mut st = me.iloop.state.lock().unwrap();
				match st.conns.get_mut(&me.key) {
					None => {
						return Poll::Ready(Err(io::Error::new(
							io::ErrorKind::BrokenPipe,
							"iroh session closed",
						)))
					}
					Some(slot) if slot.closed => {
						return Poll::Ready(Err(io::Error::new(
							io::ErrorKind::BrokenPipe,
							"iroh session closed",
						)))
					}
					Some(slot) if slot.writable => {
						slot.writable = false;
						continue;
					}
					Some(slot) => {
						slot.write_waker = Some(cx.waker().clone());
						return Poll::Pending;
					}
				}
			}
			if rc != sys::OK {
				return Poll::Ready(Err(io::Error::other(format!(
					"iroh try_write failed (code {rc})"
				))));
			}
			return Poll::Ready(Ok(count));
		}
	}

	fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
		// Writes go straight to the sidecar in `poll_write`; nothing is buffered
		// here to flush.
		Poll::Ready(Ok(()))
	}

	fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
		Poll::Ready(Ok(()))
	}
}

/// A listening iroh endpoint — the iroh sibling of [`Server`](crate::Server).
/// The native driver loop owns the multiplexed resident, listener, accept
/// handshake, and every accepted session. This type is only the public
/// listener view over that generic lifecycle.
pub struct IrohServer {
	listener: crate::listen::LoopListener,
	node_id: String,
}

impl IrohServer {
	pub async fn bind(config: IrohConfig) -> Result<IrohServer> {
		let loop_shared = crate::driver_loop::LoopShared::open_with_durable_seed(
			crate::session::HANDSHAKE_TIMEOUT.as_millis() as u32,
			crate::session::HANDSHAKE_TIMEOUT.as_millis() as u32,
			None,
		)?;
		let host = Host::from_shared(loop_shared.wrapper_host()?);
		IrohServer::bind_on_loop(loop_shared, host, config, true).await
	}

	pub async fn bind_with_seed(config: IrohConfig, seed: [u8; 32]) -> Result<IrohServer> {
		let loop_shared = crate::driver_loop::LoopShared::open_with_durable_seed(
			crate::session::HANDSHAKE_TIMEOUT.as_millis() as u32,
			crate::session::HANDSHAKE_TIMEOUT.as_millis() as u32,
			Some(seed),
		)?;
		let host = Host::from_shared(loop_shared.wrapper_host()?);
		IrohServer::bind_on_loop(loop_shared, host, config, true).await
	}

	pub async fn bind_with_host(config: IrohConfig, host: Host) -> Result<IrohServer> {
		let shared = host.shared();
		let loop_shared = shared.ensure_driver_loop(
			crate::session::HANDSHAKE_TIMEOUT.as_millis() as u32,
			crate::session::HANDSHAKE_TIMEOUT.as_millis() as u32,
		)?;
		IrohServer::bind_on_loop(loop_shared, host, config, false).await
	}

	async fn bind_on_loop(
		loop_shared: Rc<crate::driver_loop::LoopShared>,
		host: Host,
		config: IrohConfig,
		owns_loop: bool,
	) -> Result<IrohServer> {
		let host_shared = host.shared();
		let mut listener = None;
		let result = async {
			let node_id = ensure_loop_provider(&host_shared, &loop_shared, config).await?;
			let id = loop_shared.listen(crate::abi_constants::TRANSPORT_IROH, &node_id)?;
			listener = Some(id);
			loop_shared.start()?;
			Ok(IrohServer {
				listener: crate::listen::LoopListener::new(Rc::clone(&loop_shared), id, host),
				node_id,
			})
		}
		.await;
		if result.is_err() {
			if let Some(id) = listener {
				let _ = loop_shared.close_listener(id);
			}
			if owns_loop {
				loop_shared.close();
			}
		}
		result
	}

	pub fn host(&self) -> Host {
		self.listener.host()
	}

	pub fn node_id(&self) -> &str {
		&self.node_id
	}

	pub fn direct_addresses(&self) -> Result<String> {
		Ok(self
			.listener_locator()?
			.string_hint(crate::abi_constants::HINT_DIRECT_ADDRESSES)?
			.map(str::to_owned)
			.unwrap_or_default())
	}

	fn listener_locator(&self) -> Result<crate::uri::Locator> {
		self.listener.locator()
	}

	pub fn uri(&self) -> Result<String> {
		crate::uri::format_locator_uri(&self.listener.locator()?)
	}

	pub async fn accept(&self) -> Result<Session> {
		self.listener.accept().await
	}

	/// Stop iroh admission through this listener. Sessions already returned by
	/// [`IrohServer::accept`] remain live on the shared Host; [`Host::close_async`]
	/// is the terminal endpoint and session release barrier.
	pub fn close(&self) -> Result<()> {
		self.listener.close()
	}
}

// ── the iroh application surface ──────────────────────────────────────────────
// The same [`Session`] surface over iroh's encrypted QUIC: the one
// [`connect`](crate::connect) dialer routes an `ocapn://<nodeid>.iroh?…` locator
// to the binding-internal iroh dial here, and [`listen_iroh`]/[`IrohServer`] host.
// The byte-fed pump remains for a redeem on a Host that already owns
// externally supplied channels —
// `Session::establish_dialed_locator` carries the session over the iroh
// byte-stream bridge ([`IrohStream`]) exactly as over a `TcpStream`; only the
// dialed locator differs (`iroh` + endpoint id, never `tcp` + host:port). The
// default listener uses the generic driver resident and accepted-session
// lifecycle. The iroh-touching code lives here behind the `iroh`
// feature, so a tcp-only build references no iroh symbol — the same
// `libpancake_ocapn` / `libpancake_net_transport_iroh` split the other bindings
// mirror.

impl Session {
	/// Binding-internal Host-keyed iroh dial behind [`connect`](crate::connect)
	/// and handoff redeem. Application code uses
	/// `connect(locator, Some(reachability), Some(host))`.
	///
	/// This is the byte-fed iroh channel adapter used when a redeem is emitted
	/// by a Host that already owns byte-fed sessions. Ordinary bounded dials,
	/// including dials on a quiescent caller-supplied Host, use the generic
	/// driver resident.
	///
	/// `handshake_timeout` bounds the OCapN handshake only. The dial-by-id
	/// budget above it (a `Discovery` posture retries while the exporter's
	/// pkarr record propagates, ADR-0082) is already spent by the time the
	/// stream exists, so a slow discovery never eats the handshake's bound.
	pub(crate) async fn connect_iroh_with_host(
		node_id: &str,
		direct_addresses: &str,
		reachability: Reachability,
		host: Host,
		handshake_timeout: Option<std::time::Duration>,
	) -> Result<Session> {
		let stream = IrohStream::connect(node_id, direct_addresses, reachability).await?;
		// As the accept side: this module opened the connection, so it is the
		// one place that can say what QUIC proved about the far end.
		let proved = stream.remote_node_id();
		Session::establish_dialed_locator(
			host.shared(),
			crate::abi_constants::TRANSPORT_IROH,
			node_id,
			stream,
			handshake_timeout,
			proved.as_deref(),
		)
		.await
	}
}

/// Bind an iroh endpoint and return an [`IrohServer`] to accept partners on, the
/// iroh sibling of [`listen`](crate::listen). `reachability` is the mandatory
/// posture (no default). One seed drives both the endpoint and the shared
/// [`Host`] (ADR-0075). Needs the iroh ABI library (`zig build iroh-abi`).
pub async fn listen_iroh(config: IrohConfig) -> Result<IrohServer> {
	IrohServer::bind(config).await
}

/// [`listen_iroh`] with an explicit identity seed — pass the same seed after a
/// restart to keep the node id stable, and use it for any [`Host`] that must
/// share that identity.
pub async fn listen_iroh_with_seed(config: IrohConfig, seed: [u8; 32]) -> Result<IrohServer> {
	IrohServer::bind_with_seed(config, seed).await
}

pub async fn listen_iroh_with_host(config: IrohConfig, host: Host) -> Result<IrohServer> {
	IrohServer::bind_with_host(config, host).await
}
