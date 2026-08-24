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
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};

use tokio::io::unix::AsyncFd;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::{oneshot, Notify};

use crate::abi_constants::{
	BINDING_READINESS_DRAIN_CAP, DISCOVERY_DIAL_MAX_ATTEMPTS, DISCOVERY_DIAL_RETRY_MS, IROH_NODE_ID_BYTES,
};
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

const DRAIN_READY_CAP: usize = BINDING_READINESS_DRAIN_CAP;

crate::error_slot::error_slot!(
	// Like the core `check`, but for `pancake_iroh_*` calls: snapshot the iroh
	// transport's own thread-local last-error rather than the unrelated
	// ocapn-family one. A `pancake_iroh_*` call that returns PANCAKE_ERR_IO
	// records its concrete cause in this slot.
	fn check_iroh;
	fn iroh_last_error;
	ffi::pancake_iroh_last_error
);

mod sync;
use sync::lock_iroh;

mod release;
use release::NetlayerRaw;

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
/// sibling of the TCP `Netlayer`.
///
/// This wrapper is move-only. `connect_owned` and `release` consume the public
/// owner because both cross the native endpoint's release boundary. Internal
/// `Arc` clones keep the endpoint alive while a readiness task, stream, or
/// provider lease still needs it, but application code cannot mint a second
/// release owner.
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
			raw: Arc::new(NetlayerRaw::new(raw)),
			reachability: config.reachability,
		})
	}

	/// This endpoint's id, its Ed25519 public key as lowercase hex, the dialable
	/// designator and the URI host.
	pub fn node_id(&self) -> Result<String> {
		let mut buf = [0u8; IROH_NODE_ID_BYTES];
		let mut len: usize = 0;
		check_iroh(unsafe { ffi::pancake_iroh_netlayer_node_id(self.raw.raw, buf.as_mut_ptr(), buf.len(), &mut len) })?;
		Ok(String::from_utf8_lossy(&buf[..len]).into_owned())
	}

	/// Return this endpoint's archive-owned provider package.
	pub fn transport_provider(&self) -> Result<crate::driver_loop::ProviderPackage<'_>> {
		let mut package: crate::sys::PancakeTransportProvider = unsafe { core::mem::zeroed() };
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
	pub fn close(&self) {
		self.raw.close();
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
		self.raw.release().await
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
	let mut cap: usize = 0;
	let code = unsafe { ffi::pancake_iroh_netlayer_direct_addrs(raw, std::ptr::null_mut(), 0, &mut cap) };
	if code != sys::ERR_BUFFER_TOO_SMALL {
		check_iroh(code)?;
		if cap == 0 {
			return Ok(String::new());
		}
	}
	loop {
		let mut buf = vec![0u8; cap];
		let mut len: usize = 0;
		let code = unsafe { ffi::pancake_iroh_netlayer_direct_addrs(raw, buf.as_mut_ptr(), buf.len(), &mut len) };
		if code == sys::ERR_BUFFER_TOO_SMALL && len > cap {
			cap = len;
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
