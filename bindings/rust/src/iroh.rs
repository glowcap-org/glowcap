//! iroh transport for the async surface (the `iroh` feature).
//!
//! iroh's encrypted-QUIC netlayer links the Rust sidecar, which ADR-0021 keeps
//! out of the pure-Zig archives. It ships as its own optional companion library,
//! `libglowcap_net_transport_iroh`, built with `zig build iroh-abi` (needs cargo). It exports
//! only the `glowcap_iroh_*` family, so the `iroh` cargo feature links it
//! *alongside* the static core archives (core symbols come from there) and exposes a
//! dialer/listener here.
//!
//! The frame unit is identical to TCP's: one codec-self-delimited CapTP
//! message. Byte-fed iroh channels use [`Stream`], whose private
//! `IrohLoop` owns the sidecar readiness choreography for dial and explicit
//! Host-sharing paths. The default listener registers the same endpoint as a
//! resident with `driver_loop`. Its generic listener lifecycle owns accept,
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
use tokio::sync::{Notify, oneshot};

use crate::abi_constants::{BINDING_READINESS_DRAIN_CAP, IROH_NODE_ID_BYTES};
use crate::sys::iroh as ffi;
use crate::{Error, HintValue, HintWireForm, Host, Locator, Result, Session, sys};

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
	GLOWCAP_IROH_EV_ACCEPT, GLOWCAP_IROH_EV_CLOSED, GLOWCAP_IROH_EV_CONNECT, GLOWCAP_IROH_EV_READABLE,
	GLOWCAP_IROH_EV_WRITABLE, GlowcapIrohConn, GlowcapIrohNetlayer, GlowcapIrohReadyEvent,
};

const DRAIN_READY_CAP: usize = BINDING_READINESS_DRAIN_CAP;

crate::error_slot::error_slot!(
	// Like the core `check`, but for `glowcap_iroh_*` calls: snapshot the iroh
	// transport's own thread-local last-error rather than the unrelated
	// ocapn-family one. A `glowcap_iroh_*` call that returns GLOWCAP_ERR_IO
	// records its concrete cause in this slot.
	fn check_iroh;
	fn iroh_last_error;
	ffi::glowcap_iroh_last_error
);

mod sync;
use sync::lock_iroh;

mod release;
use release::NetlayerRaw;

/// One iroh endpoint's configuration, field-for-field with the header's
/// `GlowcapIrohConfig`, which documents what each setting means. `None` for a
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

impl Config {
	/// A configuration with only the mandatory posture set, every timeout left
	/// to the transport. Set the public fields for anything else.
	pub fn new(reachability: Reachability) -> Config {
		Config {
			reachability,
			connect_timeout_ms: None,
			idle_timeout_ms: None,
			worker_threads: None,
		}
	}
}

/// Listener construction options. See [`ListenerIdentity`] for the difference
/// between restoring an identity and sharing an existing Host.
#[derive(Clone, Default)]
pub struct ListenOptions {
	pub identity: ListenerIdentity,
}

/// A bound iroh QUIC endpoint plus the sidecar runtime driving it, the iroh
/// sibling of the TCP `Netlayer`.
///
/// This wrapper is move-only. `connect_owned` and `release` consume the public
/// owner because both cross the FFI endpoint's release boundary. Internal
/// `Arc` clones keep the endpoint alive while a readiness task, stream, or
/// provider lease still needs it, but application code cannot mint a second
/// release owner.
pub struct Netlayer {
	raw: Arc<NetlayerRaw>,
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
			// SAFETY: `self.netlayer.raw` is the netlayer handle `NetlayerRaw` owns, kept unreleased by the `Arc` this
			// `DialGuard` holds; `request_id` names the dial this guard admitted, which the callee cancels, and no
			// pointer is passed.
			unsafe {
				ffi::glowcap_iroh_netlayer_cancel_connect(self.netlayer.raw, self.request_id);
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
	/// `seed`: the same durable identity a [`Host`](crate::Host) must use so
	/// designator and endpoint id stay one value (ADR-0028). CapTP session
	/// signing keys still come from the Host's fresh session-key root
	/// (ADR-0028).
	pub async fn from_seed(config: Config, seed: [u8; 32]) -> Result<Netlayer> {
		tokio::task::spawn_blocking(move || Netlayer::from_seed_blocking(config, &seed))
			.await
			.map_err(|_| Error::from_code(sys::ERR_INTERNAL))?
	}

	fn from_seed_blocking(config: Config, seed: &[u8; 32]) -> Result<Netlayer> {
		crate::require_archive_fingerprint(
			"iroh",
			// SAFETY: `glowcap_iroh_archive_fingerprint` takes no arguments and returns a scalar.
			unsafe { ffi::glowcap_iroh_archive_fingerprint() },
			crate::abi_constants::IROH_ARCHIVE_FINGERPRINT,
		)?;
		let mut raw: *mut GlowcapIrohNetlayer = core::ptr::null_mut();
		// `..Default::default()` zero-fills the rest, and 0 is the built-in
		// default for every timeout: the header's zero-init contract.
		let raw_config = ffi::GlowcapIrohConfig {
			reachability: config.reachability as u32,
			connect_timeout_ms: config.connect_timeout_ms.unwrap_or(0),
			idle_timeout_ms: config.idle_timeout_ms.unwrap_or(0),
			worker_threads: config.worker_threads.unwrap_or(0),
		};
		// SAFETY: `seed` is a borrowed `&[u8; 32]` and `raw_config` a local `GlowcapIrohConfig`, both live for the
		// call, and the callee copies the seed; `raw` is a local out-parameter the callee fills with the new netlayer
		// handle, and the three null and zero diagnostic arguments omit the error capture.
		check_iroh(unsafe {
			ffi::glowcap_iroh_netlayer_new(
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
		})
	}

	/// This endpoint's id, its Ed25519 public key as lowercase hex, the dialable
	/// designator and the URI host.
	pub fn node_id(&self) -> Result<String> {
		let mut buf = [0u8; IROH_NODE_ID_BYTES];
		let mut len: usize = 0;
		// SAFETY: `self.raw.raw` is the netlayer handle `NetlayerRaw` owns, kept unreleased by the `Arc` in `self.raw`;
		// `buf` is a local array of `IROH_NODE_ID_BYTES`, the capacity the header requires, and `len` is a local
		// out-parameter, both written by the callee.
		check_iroh(unsafe { ffi::glowcap_iroh_netlayer_node_id(self.raw.raw, buf.as_mut_ptr(), buf.len(), &mut len) })?;
		Ok(String::from_utf8_lossy(&buf[..len]).into_owned())
	}

	/// Return this endpoint's archive-owned provider package.
	pub fn transport_provider(&self) -> Result<crate::driver_loop::ProviderPackage<'_>> {
		// SAFETY: `GlowcapTransportProvider` is a plain C struct of integers and null pointers; all-zero is a valid
		// value, and the callee fills it before it is read.
		let mut package: crate::sys::GlowcapTransportProvider = unsafe { core::mem::zeroed() };
		// SAFETY: `self.raw.raw` is the netlayer handle `NetlayerRaw` owns, kept unreleased by the `Arc` in `self.raw`;
		// `package` is a local out-parameter the callee fills, and the returned `ProviderPackage` borrows `self` so the
		// handle outlives it.
		check_iroh(unsafe { ffi::glowcap_iroh_transport_provider(self.raw.raw, &mut package) })?;
		Ok(crate::driver_loop::ProviderPackage {
			package,
			_owner: core::marker::PhantomData,
		})
	}

	/// This endpoint's comma-separated direct socket addresses, the hint string a
	/// partner passes to dial it relay-less, or `None` while the endpoint has
	/// gathered none: a relay-only endpoint may never carry any, the same shape
	/// [`Server::direct_addresses`] reads off the canonical locator.
	pub fn direct_addresses(&self) -> Result<Option<String>> {
		direct_addresses(self.raw.raw)
	}

	/// Close and release this endpoint, joining the one FFI release task.
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

	/// Hand this endpoint's lifetime to a driver that has already retained its
	/// provider package, the way the Python and TypeScript bindings transfer a
	/// netlayer after `installProvider`. The driver's provider lease is the
	/// endpoint's lifetime authority from here on: the endpoint keeps running
	/// under that lease and is torn down at loop teardown, while this
	/// construction reference is released without a close. Refused once any
	/// connection or readiness loop has borrowed the endpoint, because those
	/// would outlive the reference they came from.
	pub async fn relinquish_to_provider(self) -> Result<()> {
		if Arc::strong_count(&self.raw) != 1 {
			return Err(Error::with_detail(
				sys::ERR_INVALID_ARGUMENT,
				"iroh netlayer is not transferable while a connection or loop borrows it".to_string(),
			));
		}
		self.raw.relinquish().await
	}

	/// Dial a partner by endpoint id and direct-address hints over the
	/// event-driven loop surface (ADR-0019), returning the byte stream that
	/// carries the OCapN session. Dial establishment and frame I/O are both
	/// driven by the stream's readiness loop. The returned stream owns this netlayer's
	/// lifetime (an ephemeral dialing endpoint released with the connection).
	pub async fn connect_owned(self, node_id: &str, direct_addresses: &str) -> Result<Stream> {
		let iloop = IrohLoop::start(Arc::clone(&self.raw))?;
		// If this future is dropped (cancelled) while the dial is awaiting, the
		// guard's `Drop` shuts the loop down so the dispatcher task releases its
		// endpoint rather than leaking it. The `?` below routes an early dial
		// failure through the same shutdown.
		let mut guard = LoopGuard {
			iloop: Arc::clone(&iloop),
			armed: true,
		};
		// One transport attempt. A dial staged through the driver loop retries
		// transient faults on the runtime's `GLOWCAP_DISCOVERY_DIAL_*` budget
		// (ADR-0018); a raw transport dial reports its first fault.
		let conn = iloop.dial(node_id, direct_addresses).await?;
		// Dial succeeded: ownership of the loop moves into the returned stream,
		// whose `Drop` owns the shutdown, so disarm the cancel guard.
		guard.armed = false;
		iloop.register(conn);
		Ok(Stream::new(conn as *mut GlowcapIrohConn, iloop, Some(self), true))
	}
}

// The FFI endpoint reports no addresses as a zero-length answer; that is
// `None` here rather than an empty string, so no caller acts on an empty
// stand-in.
fn direct_addresses(raw: *mut GlowcapIrohNetlayer) -> Result<Option<String>> {
	let mut cap: usize = 0;
	// SAFETY: `raw` is the netlayer handle of a `NetlayerRaw` that the caller keeps unreleased for this call; the null
	// output with capacity zero asks for the size only, and `cap` is a local out-parameter the callee writes.
	let code = unsafe { ffi::glowcap_iroh_netlayer_direct_addrs(raw, std::ptr::null_mut(), 0, &mut cap) };
	if code != sys::ERR_BUFFER_TOO_SMALL {
		check_iroh(code)?;
		if cap == 0 {
			return Ok(None);
		}
	}
	loop {
		let mut buf = vec![0u8; cap];
		let mut len: usize = 0;
		// SAFETY: as the first `glowcap_iroh_netlayer_direct_addrs` call above for `raw`; `buf` is a live local
		// `Vec<u8>` of `buf.len()` bytes the callee writes during the call, and `len` is a local out-parameter.
		let code = unsafe { ffi::glowcap_iroh_netlayer_direct_addrs(raw, buf.as_mut_ptr(), buf.len(), &mut len) };
		if code == sys::ERR_BUFFER_TOO_SMALL && len > cap {
			cap = len;
			continue;
		}
		check_iroh(code)?;
		if len == 0 {
			return Ok(None);
		}
		return Ok(Some(String::from_utf8_lossy(&buf[..len]).into_owned()));
	}
}

/// Attach the Host's one configured iroh endpoint to its driver loop. The
/// endpoint identity comes from the Host, while the FFI driver decides
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
	// The driver holds the provider lease, the endpoint's lifetime
	// authority. Dropping the construction reference instead would close the
	// endpoint under that lease and refuse every later dial as a closed
	// endpoint.
	netlayer.relinquish_to_provider().await?;
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
/// normally prefer [`provider`]. This form is for an embedder that
/// owns channel pumping. A hinted handoff redeem uses direct reachability,
/// while an ordinary connect uses the configured posture.
pub fn connector(config: Config) -> crate::Result<crate::Connector> {
	crate::Connector::new(
		&[crate::abi_constants::TRANSPORT_IROH],
		move |host, locator, origin, _transport_options, timeout| {
			Box::pin(async move {
				let addresses = locator
					.string_hint(crate::abi_constants::HINT_DIRECT_ADDRESSES)?
					.unwrap_or("");
				let reachability = if matches!(origin, crate::DialOrigin::Pending { .. }) && !addresses.is_empty() {
					Reachability::Direct
				} else {
					config.reachability
				};
				Session::connect_iroh_with_host(&locator.designator, addresses, reachability, host, timeout).await
			})
		},
	)
}

mod reactor;
use reactor::{ConnPtr, IrohLoop};

/// A byte stream over one iroh QUIC connection: the iroh sibling of a
/// `TcpStream` for the [`Session`] driver. Inbound bytes
/// come from the sidecar's non-blocking `try_read`. The peer re-frames them.
/// Outbound bytes go through `try_write`, re-arming on the next writable record
/// when the sidecar buffer is full. Its readiness loop, not a parked blocking
/// read, decides when bytes move. `close().await` is the explicit teardown
/// barrier: a dialer (`owns_loop`) joins its loop and releases its ephemeral
/// endpoint. An accepted stream leaves the server's loop and releases its
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

/// A listening iroh endpoint: the iroh sibling of [`crate::tcp::Server`].
/// The FFI driver loop owns the multiplexed resident, listener, accept
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
/// [`Host`] (ADR-0028). Needs the iroh ABI library (`zig build iroh-abi`).
pub async fn listen(config: Config, options: ListenOptions) -> Result<Server> {
	Server::bind(config, options).await
}
