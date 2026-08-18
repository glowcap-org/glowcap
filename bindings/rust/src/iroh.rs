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
//! message. Byte-fed iroh channels use [`Stream`], whose private
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
use crate::{sys, Error, HintValue, HintWireForm, Host, Locator, Result, Session};

pub use crate::ListenerIdentity;

/// How an iroh endpoint becomes reachable. There is no default: enabling
/// relays or discovery is a transport-package decision the caller makes in
/// [`Config`].
#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Reachability {
	Direct = crate::abi_constants::IROH_REACH_DIRECT,
	Discovery = crate::abi_constants::IROH_REACH_DISCOVERY,
	DiscoveryNoRelay = crate::abi_constants::IROH_REACH_DISCOVERY_NO_RELAY,
	LocalDiscovery = crate::abi_constants::IROH_REACH_LOCAL_DISCOVERY,
}

/// Build an iroh locator, optionally carrying direct socket addresses.
pub fn locator(node_id: &str, direct_addresses: Option<&str>) -> Locator {
	let mut hints = std::collections::BTreeMap::new();
	if let Some(addresses) = direct_addresses {
		hints.insert(
			crate::HINT_DIRECT_ADDRESSES.to_string(),
			HintValue::String(addresses.to_string()),
		);
	}
	Locator {
		transport: crate::TRANSPORT_IROH.to_string(),
		designator: node_id.to_string(),
		hints,
		hint_wire_form: if direct_addresses.is_some() {
			HintWireForm::Map
		} else {
			HintWireForm::BooleanFalse
		},
	}
}

use ffi::{
	PancakeIrohConn, PancakeIrohNetlayer, PancakeIrohReadyEvent, PANCAKE_IROH_EV_ACCEPT, PANCAKE_IROH_EV_CLOSED,
	PANCAKE_IROH_EV_CONNECT, PANCAKE_IROH_EV_READABLE, PANCAKE_IROH_EV_WRITABLE,
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

type ReleaseFn = unsafe fn(usize) -> i32;

fn call_release(release: ReleaseFn, raw: usize) -> Result<()> {
	match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| unsafe { release(raw) })) {
		Ok(code) => check_iroh(code),
		Err(_) => Err(Error::with_detail(
			sys::ERR_INTERNAL,
			"iroh netlayer release panicked".to_string(),
		)),
	}
}

/// No iroh mutex protects an application invariant: critical sections only
/// move owned task handles, readiness flags, wakers, and channel endpoints.
/// If a panic poisons one, the contained values remain valid. Recover the
/// guard, clear the sticky poison bit, and publish the containment event rather
/// than turning every later library call into another process panic.
fn lock_iroh<'a, T>(mutex: &'a Mutex<T>, source: &'static str) -> std::sync::MutexGuard<'a, T> {
	recover_iroh_lock(mutex, mutex.lock(), source)
}

fn recover_iroh_lock<'a, T>(
	mutex: &'a Mutex<T>,
	result: std::sync::LockResult<std::sync::MutexGuard<'a, T>>,
	source: &'static str,
) -> std::sync::MutexGuard<'a, T> {
	match result {
		Ok(guard) => guard,
		Err(poisoned) => {
			let guard = poisoned.into_inner();
			mutex.clear_poison();
			crate::record_runtime_failure(
				crate::FailureLayer::Transport,
				source,
				Error::with_detail(sys::ERR_INTERNAL, "iroh synchronization state was poisoned".to_string()),
			);
			guard
		}
	}
}

// A release task is retained until its blocking call has completed. The
// reserved/running split lets a last-resort Drop fallback claim a queued task
// after Tokio starts shutting down: the task then observes the running claim
// and skips the native call, so release remains exactly once.
struct NetlayerRelease {
	phase: AtomicU8,
	task: Mutex<Option<JoinHandle<()>>>,
	notify: Notify,
	close_lock: tokio::sync::Mutex<()>,
	failure: Mutex<Option<Error>>,
}

impl NetlayerRelease {
	fn new() -> NetlayerRelease {
		NetlayerRelease {
			phase: AtomicU8::new(RELEASE_OPEN),
			task: Mutex::new(None),
			notify: Notify::new(),
			close_lock: tokio::sync::Mutex::new(()),
			failure: Mutex::new(None),
		}
	}

	fn start(self: &Arc<NetlayerRelease>, raw: usize, release: ReleaseFn) {
		// Store the JoinHandle before a waiter can take it, even if the blocking
		// task runs to completion immediately.
		let mut task_slot = lock_iroh(&self.task, "iroh-release-task-lock-poison");
		if self
			.phase
			.compare_exchange(RELEASE_OPEN, RELEASE_RESERVED, Ordering::AcqRel, Ordering::Acquire)
			.is_err()
		{
			return;
		}
		let state = Arc::clone(self);
		let task = tokio::task::spawn_blocking(move || {
			if state
				.phase
				.compare_exchange(RELEASE_RESERVED, RELEASE_RUNNING, Ordering::AcqRel, Ordering::Acquire)
				.is_ok()
			{
				if let Err(error) = call_release(release, raw) {
					*lock_iroh(&state.failure, "iroh-release-failure-lock-poison") = Some(error);
				}
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
		let task = lock_iroh(&self.task, "iroh-release-task-lock-poison").take();
		if let Some(task) = task {
			task.await.map_err(|_| Error::from_code(sys::ERR_INTERNAL))?;
		}
		loop {
			if self.phase.load(Ordering::Acquire) == RELEASE_DONE {
				return match lock_iroh(&self.failure, "iroh-release-failure-lock-poison").clone() {
					Some(error) => Err(error),
					None => Ok(()),
				};
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
				if let Err(error) = call_release(release, raw) {
					*lock_iroh(&self.failure, "iroh-release-failure-lock-poison") = Some(error.clone());
					crate::record_runtime_failure(crate::FailureLayer::Transport, "iroh-netlayer-finalize", error);
				}
				self.phase.store(RELEASE_DONE, Ordering::Release);
				self.notify.notify_waiters();
				return;
			}
		}
	}
}

unsafe fn release_native(raw: usize) -> i32 {
	ffi::pancake_iroh_netlayer_release(
		raw as *mut PancakeIrohNetlayer,
		core::ptr::null_mut(),
		0,
		core::ptr::null_mut(),
	)
}

// The raw netlayer handle is shared (behind an `Arc`) between the public
// `Netlayer`/`Server` and the readiness loop's dispatcher task. Explicit
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
pub struct Config {
	pub reachability: Reachability,
	pub connect_timeout_ms: Option<u64>,
	pub idle_timeout_ms: Option<u64>,
	pub worker_threads: Option<u32>,
}

/// Listener construction options. See [`ListenerIdentity`] for the difference
/// between restoring an identity and sharing an existing Host.
#[derive(Clone, Default)]
pub struct ListenOptions {
	pub identity: ListenerIdentity,
}

mod config;

/// A bound iroh QUIC endpoint plus the sidecar runtime driving it, the iroh
/// sibling of the TCP `Netlayer`. Dial with
/// [`Netlayer::connect_owned`] or host with [`Server`]. Call
/// [`Netlayer::release`] after every connection minted from it is released;
/// Drop is only the last-resort fallback.
#[derive(Clone)]
pub struct Netlayer {
	raw: Arc<NetlayerRaw>,
	reachability: Reachability,
}

// Shuts a freshly-started loop down if the `connect_owned` future is dropped
// before the dial completes. `IrohLoop::run` never returns until `shutdown`, and
// `IrohLoop` has no `Drop`, so a cancelled dial would otherwise leak the endpoint
// (a live QUIC socket), the duped readiness fd, and the parked dispatcher task
// through the task's retained `Arc<IrohLoop>`. Disarmed the instant the dial
// succeeds and the loop moves into the returned `Stream` (whose `Drop` then
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

impl Netlayer {
	/// Bind an iroh endpoint with a fresh random Ed25519 key and the caller's
	/// chosen [`Reachability`], the mandatory posture deciding whether the
	/// endpoint uses relays or a discovery service. There is no default. Binds
	/// the endpoint and arms its readiness loop.
	pub async fn new(config: Config) -> Result<Netlayer> {
		let mut seed = [0u8; 32];
		getrandom::fill(&mut seed).map_err(|error| {
			Error::with_detail(sys::ERR_IO, format!("drawing the iroh endpoint seed failed: {error}"))
		})?;
		Netlayer::from_seed(config, seed).await
	}

	/// Bind an iroh endpoint whose Ed25519 identity is reconstructed from
	/// `seed` — the same durable identity a [`Host`](crate::Host) must use so
	/// designator and endpoint id stay one value (ADR-0075). CapTP session
	/// signing keys still come from the Host's fresh session-key root
	/// (ADR-0097).
	pub async fn from_seed(config: Config, seed: [u8; 32]) -> Result<Netlayer> {
		tokio::task::spawn_blocking(move || Netlayer::from_seed_blocking(config, &seed))
			.await
			.map_err(|_| Error::from_code(sys::ERR_INTERNAL))?
	}

	fn from_seed_blocking(config: Config, seed: &[u8; 32]) -> Result<Netlayer> {
		crate::require_archive_fingerprint(
			"iroh",
			unsafe { ffi::pancake_iroh_archive_fingerprint() },
			crate::abi_constants::IROH_ARCHIVE_FINGERPRINT,
		)?;
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
			ffi::pancake_iroh_netlayer_new(
				seed.as_ptr(),
				seed.len(),
				&raw_config,
				&mut raw,
				core::ptr::null_mut(),
				0,
				core::ptr::null_mut(),
			)
		})?;
		Ok(Netlayer {
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
		check_iroh(unsafe { ffi::pancake_iroh_netlayer_node_id(self.raw.raw, buf.as_mut_ptr(), buf.len(), &mut len) })?;
		Ok(String::from_utf8_lossy(&buf[..len]).into_owned())
	}

	/// Return this endpoint's archive-owned provider package.
	pub fn transport_provider(&self) -> Result<crate::driver_loop::ProviderPackage<'_>> {
		let mut package: crate::sys::driver::PancakeTransportProvider = unsafe { core::mem::zeroed() };
		check_iroh(unsafe { ffi::pancake_iroh_transport_provider(self.raw.raw, &mut package) })?;
		Ok(crate::driver_loop::ProviderPackage {
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
		self.raw.release.start(self.raw.raw as usize, release_native);
		let release_result = self.raw.release.wait().await;
		match close_result {
			Ok(()) => release_result,
			Err(primary) => Err(crate::retain_cleanup_failure(primary, release_result)),
		}
	}

	/// Dial a partner by endpoint id and direct-address hints over the
	/// event-driven loop surface (ADR-0057), returning the byte stream that
	/// carries the OCapN session. Dial establishment and frame I/O are both
	/// driven by the stream's readiness loop. The returned stream owns this netlayer's
	/// lifetime (an ephemeral dialing endpoint released with the connection).
	pub async fn connect_owned(self, node_id: &str, direct_addresses: &str) -> Result<Stream> {
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
		Ok(Stream::new(conn as *mut PancakeIrohConn, iloop, Some(self), true))
	}
}

fn direct_addresses(raw: *mut PancakeIrohNetlayer) -> Result<String> {
	// The endpoint with no direct addresses writes zero bytes; a buffer too
	// small is ERR_BUFFER_TOO_SMALL, so grow until it fits.
	let mut cap = 256usize;
	loop {
		let mut buf = vec![0u8; cap];
		let mut len: usize = 0;
		let code = unsafe { ffi::pancake_iroh_netlayer_direct_addrs(raw, buf.as_mut_ptr(), buf.len(), &mut len) };
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
	config: Config,
) -> Result<String> {
	host.guard_handle()?;
	let netlayer = Netlayer::from_seed(config, host.durable_seed()).await?;
	let node_id = netlayer.node_id()?;
	lp.add_provider(netlayer.transport_provider()?)?;
	Ok(node_id)
}

/// Configure an iroh endpoint package for a generic [`crate::Runtime::connect`]
/// operation. Reachability belongs to this provider configuration, not to the
/// transport-neutral connection options.
pub fn provider(config: Config) -> crate::driver_loop::Provider {
	crate::driver_loop::Provider::new(move |lp| async move {
		let host = lp.wrapper_host()?;
		ensure_loop_provider(&host, &lp, config).await?;
		Ok(())
	})
}

/// Configure an explicit byte-fed iroh connector. Native applications should
/// normally prefer [`provider`]; this form is for an embedder that deliberately
/// owns channel pumping. A hinted handoff redeem uses direct reachability,
/// while an ordinary connect uses the configured posture.
pub fn connector(config: Config) -> crate::Result<crate::Connector> {
	crate::Connector::new(
		&[crate::abi_constants::TRANSPORT_IROH],
		move |host, locator, redeem, _transport_options, timeout| {
			Box::pin(async move {
				let addresses = locator
					.string_hint(crate::abi_constants::HINT_DIRECT_ADDRESSES)?
					.unwrap_or("");
				let reachability = if redeem && !addresses.is_empty() {
					Reachability::Direct
				} else {
					config.reachability
				};
				Session::connect_iroh_with_host(&locator.designator, &addresses, reachability, host, timeout).await
			})
		},
	)
}

// Discovery-posture dial retry (ADR-0082): lockstep with `PANCAKE_DISCOVERY_DIAL_*`.
// Only transient dial faults (projected as `ERR_IO`) are retried; permanent
// faults (`InvalidArgument`, `Internal`, …) surface immediately.
async fn dial_resolving(iloop: &Arc<IrohLoop>, node_id: &str, hints: &str, retry: bool) -> Result<usize> {
	let mut attempt: u32 = 1;
	loop {
		match iloop.dial(node_id, hints).await {
			Ok(conn) => return Ok(conn),
			Err(e) => {
				if e.kind() != crate::ErrorKind::Io || !retry || attempt >= DISCOVERY_DIAL_MAX_ATTEMPTS as u32 {
					return Err(e);
				}
			}
		}
		attempt += 1;
		tokio::time::sleep(std::time::Duration::from_millis(DISCOVERY_DIAL_RETRY_MS as u64)).await;
	}
}

mod reactor;
use reactor::{ConnPtr, IrohLoop};

/// A byte stream over one iroh QUIC connection: the iroh sibling of a
/// `TcpStream` for the [`Session`] driver. Inbound bytes
/// come from the sidecar's non-blocking `try_read`; the peer re-frames them.
/// Outbound bytes go through `try_write`, re-arming on the next writable record
/// when the sidecar buffer is full. Its readiness loop, not a parked blocking
/// read, decides when bytes move. `close().await` is the explicit teardown
/// barrier: a dialer (`owns_loop`) joins its loop and releases its ephemeral
/// endpoint; an accepted stream leaves the server's loop and releases its
/// connection. Dropping is only the last-resort fallback.
pub struct Stream {
	conn: Option<ConnPtr>,
	key: usize,
	registered: bool,
	iloop: Arc<IrohLoop>,
	owns_loop: bool,
	// A dialer's ephemeral endpoint, released after this stream's loop and
	// connection are torn down.
	owned_netlayer: Option<Netlayer>,
}

mod stream;

/// A listening iroh endpoint — the iroh sibling of [`crate::tcp::Server`].
/// The native driver loop owns the multiplexed resident, listener, accept
/// handshake, and every accepted session. This type is only the public
/// listener view over that generic lifecycle.
pub struct Server {
	listener: crate::server::LoopListener,
	node_id: String,
}

mod server;

/// Bind an iroh endpoint and return an [`Server`] to accept partners on.
/// `reachability` is the mandatory
/// posture (no default). One seed drives both the endpoint and the shared
/// [`Host`] (ADR-0075). Needs the iroh ABI library (`zig build iroh-abi`).
pub async fn listen(config: Config, options: ListenOptions) -> Result<Server> {
	Server::bind(config, options).await
}
