//! The blocking Tor onion transport (the `onion` feature).
//!
//! This module wraps `libpancake_net_transport_onion` — the `pancake_onion_*`
//! archive that the `onion` Cargo feature links (ADR-0059). `onion` is the one
//! netlayer the OCapN draft standardizes, and the one upstream Spritely Goblins
//! ships, so it is where a pancake peer and a Goblins vat meet on ground neither
//! invented.
//!
//! **pancake starts no Tor.** A [`Netlayer`] is built from a [`Config`] naming
//! where an already-running daemon listens: its SOCKS endpoint to dial, and its
//! control endpoint to host. Each is an absolute Unix socket path or a
//! `host:port`. A netlayer with no control endpoint can dial and cannot host, and
//! [`Netlayer::listen`] says so rather than pretending.
//!
//! Two limits are worth reading before relying on this, and both are ADR-0108
//! decisions rather than implementation details. A service id is an **address,
//! not an identity**: Tor proves the far end of the circuit holds the key the
//! address encodes, but the CapTP peer is whoever holds the local endpoint that
//! service forwards to. And an accepted circuit carries **no client identity at
//! all**, because Tor tells a hidden service nothing about who dialed it, so a
//! partner's claimed location on that side is unverified.
//!
//! Otherwise the frame shuttle is [`inproc`](crate::inproc)'s and
//! [`tcp`](crate::tcp)'s: a [`Connection`] reads and writes one whole CapTP frame
//! at a time, and the frame methods block. Every call that reaches Tor blocks,
//! and a circuit takes seconds rather than milliseconds.
//!
//! Errors from a `pancake_onion_*` call route through the transport archive's own
//! thread-local last-error (`pancake_onion_last_error`), never the ocapn family's
//! [`last_error`](crate::last_error).

use core::marker::PhantomData;
use std::sync::{Arc, Mutex};

#[cfg(feature = "async")]
use std::rc::Rc;

use crate::error_slot::error_slot;
use crate::sys::onion as ffi;
use crate::{Codec, Context, Error, HintWireForm, Locator, Result};

fn lock_failure(slot: &Mutex<Option<Error>>) -> std::sync::MutexGuard<'_, Option<Error>> {
	slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[cfg(feature = "async")]
pub use crate::ListenerIdentity;

/// Build the standardized hint-free locator for an onion service.
pub fn locator(service_id: &str) -> Locator {
	Locator {
		transport: crate::abi_constants::TRANSPORT_ONION.to_string(),
		designator: service_id.to_string(),
		hints: std::collections::BTreeMap::new(),
		hint_wire_form: HintWireForm::BooleanFalse,
	}
}

error_slot!(
	// Like the core `check`, but for `pancake_onion_*` calls: snapshot the onion
	// transport's own thread-local last-error.
	fn check_onion;
	fn onion_last_error;
	ffi::pancake_onion_last_error
);

/// How the control endpoint expects to be authenticated.
///
/// These are the three forms a real `torrc` produces. [`Auth::None`] is what an
/// unauthenticated Unix control socket gives, and what upstream Goblins assumes;
/// [`Auth::Cookie`] is the common default on a distribution's Tor package.
#[derive(Debug, Clone, Copy, Default)]
pub enum Auth<'a> {
	#[default]
	None,
	/// The bytes of the file `CookieAuthFile` names, which the transport sends as
	/// hexadecimal. Read the file yourself; the transport does no I/O of its own
	/// to find it.
	Cookie(&'a [u8]),
	/// The cleartext of a `HashedControlPassword` setup.
	Password(&'a str),
}

/// Where Tor listens and what to ask it for.
///
/// `socks` is required. Everything else is optional, and the defaults are the
/// dial-only posture: no control endpoint, so no hosting; no stored key, so a
/// fresh service; no forward endpoint, so a loopback port pancake binds and
/// reports to Tor.
#[derive(Debug, Clone)]
pub struct Config<'a> {
	/// Tor's SOCKS endpoint: an absolute Unix socket path, or a `host:port`.
	pub socks: &'a str,
	/// Tor's control endpoint, in the same two forms. Empty means dial-only.
	pub control: &'a str,
	pub auth: Auth<'a>,
	/// The key that restores an existing service, exactly as
	/// [`Listener::service_key`] reported it. Empty asks for a fresh service.
	pub service_key: &'a [u8],
	/// The local endpoint Tor forwards the service's virtual port to. Empty binds
	/// a loopback port and reports the one the OS chose.
	pub forward: &'a str,
}

/// Listener construction options. See [`ListenerIdentity`] for the difference
/// between restoring an identity and sharing an existing Host.
#[cfg(feature = "async")]
#[derive(Clone, Default)]
pub struct ListenOptions {
	pub identity: ListenerIdentity,
}

impl<'a> Config<'a> {
	/// A dial-only configuration: this netlayer can reach onion services and
	/// cannot host one.
	pub fn dial_only(socks: &'a str) -> Config<'a> {
		Config {
			socks,
			control: "",
			auth: Auth::None,
			service_key: &[],
			forward: "",
		}
	}

	/// Add a control endpoint, which is what makes hosting possible.
	pub fn with_control(mut self, control: &'a str, auth: Auth<'a>) -> Config<'a> {
		self.control = control;
		self.auth = auth;
		self
	}

	/// Restore the service `key` names instead of asking for a fresh one, so the
	/// same onion address comes back across a restart.
	pub fn with_service_key(mut self, key: &'a [u8]) -> Config<'a> {
		self.service_key = key;
		self
	}

	/// Name the local endpoint Tor should forward to, instead of letting pancake
	/// bind a loopback port.
	pub fn with_forward(mut self, forward: &'a str) -> Config<'a> {
		self.forward = forward;
		self
	}

	fn to_c(&self) -> ffi::PancakeOnionConfig {
		let (auth_kind, secret): (core::ffi::c_uint, &[u8]) = match self.auth {
			Auth::None => (ffi::ONION_AUTH_NONE, &[]),
			Auth::Cookie(bytes) => (ffi::ONION_AUTH_COOKIE, bytes),
			Auth::Password(text) => (ffi::ONION_AUTH_PASSWORD, text.as_bytes()),
		};
		ffi::PancakeOnionConfig {
			socks: self.socks.as_ptr(),
			socks_len: self.socks.len(),
			control_endpoint: self.control.as_ptr(),
			control_endpoint_len: self.control.len(),
			auth_kind,
			auth_secret: secret.as_ptr(),
			auth_secret_len: secret.len(),
			service_key: self.service_key.as_ptr(),
			service_key_len: self.service_key.len(),
			forward: self.forward.as_ptr(),
			forward_len: self.forward.len(),
		}
	}

	fn to_owned(&self) -> OwnedConfig {
		OwnedConfig {
			socks: self.socks.to_owned(),
			control: self.control.to_owned(),
			auth: match self.auth {
				Auth::None => OwnedAuth::None,
				Auth::Cookie(bytes) => OwnedAuth::Cookie(bytes.to_vec()),
				Auth::Password(text) => OwnedAuth::Password(text.to_owned()),
			},
			service_key: self.service_key.to_vec(),
			forward: self.forward.to_owned(),
		}
	}
}

#[derive(Clone)]
struct OwnedConfig {
	socks: String,
	control: String,
	auth: OwnedAuth,
	service_key: Vec<u8>,
	forward: String,
}

#[derive(Clone)]
enum OwnedAuth {
	None,
	Cookie(Vec<u8>),
	Password(String),
}

impl OwnedConfig {
	fn as_config(&self) -> Config<'_> {
		Config {
			socks: &self.socks,
			control: &self.control,
			auth: match &self.auth {
				OwnedAuth::None => Auth::None,
				OwnedAuth::Cookie(bytes) => Auth::Cookie(bytes),
				OwnedAuth::Password(text) => Auth::Password(text),
			},
			service_key: &self.service_key,
			forward: &self.forward,
		}
	}
}

/// Configure the onion provider package for a generic [`crate::Runtime::connect`]
/// operation. The configuration is copied at construction so the provider's
/// lifetime is independent of the caller's borrowed [`Config`].
#[cfg(feature = "async")]
pub fn provider(config: Config<'_>) -> crate::driver_loop::Provider {
	let config = config.to_owned();
	crate::driver_loop::Provider::new(move |lp| {
		let config = config.clone();
		async move {
			let netlayer = Netlayer::new(&config.as_config())?;
			lp.add_provider(netlayer.transport_provider()?)
		}
	})
}

#[cfg(all(feature = "async", test))]
fn install_provider(driver: &crate::driver_loop::DriverLoop, config: &Config<'_>) -> Result<()> {
	let netlayer = Netlayer::new(config)?;
	driver.add_provider(netlayer.transport_provider()?)
}

#[cfg(feature = "async")]
fn ensure_loop_provider(lp: &Rc<crate::driver_loop::LoopShared>, config: &Config<'_>) -> Result<()> {
	let netlayer = Netlayer::new(config)?;
	lp.add_provider(netlayer.transport_provider()?)
}

/// Owns where Tor listens and the one I/O backend its streams block on.
/// Connections and listeners borrow it (via `&self`), so the borrow checker
/// rejects a [`Connection`] or [`Listener`] that outlives the netlayer that
/// produced it. The `'ctx` lifetime additionally ties a context-backed netlayer
/// to its [`Context`].
pub struct Netlayer<'ctx> {
	raw: *mut ffi::PancakeOnionNetlayer,
	listener_close_failure: Arc<Mutex<Option<Error>>>,
	_ctx: PhantomData<&'ctx Context>,
}

impl<'ctx> Netlayer<'ctx> {
	/// Build a netlayer from `config`, on the library-owned allocator.
	///
	/// The configuration text is copied in, so `config`'s borrows need not
	/// outlive this call.
	pub fn new(config: &Config<'_>) -> Result<Netlayer<'ctx>> {
		let c = config.to_c();
		let mut raw: *mut ffi::PancakeOnionNetlayer = core::ptr::null_mut();
		check_onion(unsafe { ffi::pancake_onion_netlayer_new(&c, &mut raw) })?;
		Ok(Netlayer {
			raw,
			listener_close_failure: Arc::new(Mutex::new(None)),
			_ctx: PhantomData,
		})
	}

	/// As [`Netlayer::new`], allocating through `context`. The context must
	/// outlive the netlayer, which `'ctx` enforces.
	pub fn new_in(context: &'ctx Context, config: &Config<'_>) -> Result<Netlayer<'ctx>> {
		let c = config.to_c();
		let mut raw: *mut ffi::PancakeOnionNetlayer = core::ptr::null_mut();
		check_onion(unsafe { ffi::pancake_onion_netlayer_new_in(context.raw(), &c, &mut raw) })?;
		Ok(Netlayer {
			raw,
			listener_close_failure: Arc::new(Mutex::new(None)),
			_ctx: PhantomData,
		})
	}

	#[cfg(feature = "async")]
	fn transport_provider(&self) -> Result<crate::driver_loop::ProviderPackage<'_>> {
		let mut package: crate::sys::driver::PancakeTransportProvider = unsafe { core::mem::zeroed() };
		check_onion(unsafe { ffi::pancake_onion_transport_provider(self.raw, &mut package) })?;
		Ok(crate::driver_loop::ProviderPackage {
			package,
			_owner: PhantomData,
		})
	}

	/// Ask Tor for an onion service and bind its local end.
	///
	/// Requires a control endpoint in the [`Config`]; without one this fails
	/// rather than reporting a service nothing could reach. Blocking: the control
	/// conversation is several round trips to the daemon.
	pub fn listen(&self) -> Result<Listener<'_>> {
		let mut id = [0u8; ffi::ONION_SERVICE_ID_LEN];
		let mut id_len: usize = 0;
		let mut key = [0u8; ffi::ONION_SERVICE_KEY_CAP];
		let mut key_len: usize = 0;
		let mut raw: *mut ffi::PancakeOnionListener = core::ptr::null_mut();
		check_onion(unsafe {
			ffi::pancake_onion_listen(
				self.raw,
				id.as_mut_ptr(),
				id.len(),
				&mut id_len,
				key.as_mut_ptr(),
				key.len(),
				&mut key_len,
				&mut raw,
			)
		})?;
		Ok(Listener {
			raw,
			id,
			id_len,
			key,
			key_len,
			close_failure: Arc::clone(&self.listener_close_failure),
			_nl: PhantomData,
		})
	}

	/// Dial the onion service `service_id` through the configured Tor, framing on
	/// `codec` with an inbound cap of `max_frame_bytes`.
	///
	/// `service_id` is the bare version 3 designator: 56 base32 characters with no
	/// `.onion` suffix, which a locator's transport label supplies. One that is
	/// not a well-formed v3 address is refused before any socket opens. Blocking:
	/// a Tor circuit takes seconds.
	pub fn connect(&self, service_id: &str, codec: Codec, max_frame_bytes: usize) -> Result<Connection<'_>> {
		let mut raw: *mut ffi::PancakeOnionConn = core::ptr::null_mut();
		check_onion(unsafe {
			ffi::pancake_onion_connect(
				self.raw,
				service_id.as_ptr(),
				service_id.len(),
				codec.to_c(),
				max_frame_bytes,
				&mut raw,
			)
		})?;
		Ok(Connection { raw, _nl: PhantomData })
	}

	/// Return and clear the first listener failure retained by implicit drop.
	pub fn take_listener_close_failure(&self) -> Option<Error> {
		lock_failure(&self.listener_close_failure).take()
	}

	/// Release the netlayer and report any listener close failure retained by
	/// implicit destruction. The borrow checker guarantees every listener has
	/// already retired before this consuming barrier can run.
	pub fn close(mut self) -> Result<()> {
		let listener_failure = self.take_listener_close_failure();
		let raw = core::mem::replace(&mut self.raw, core::ptr::null_mut());
		let release = check_onion(unsafe { ffi::pancake_onion_netlayer_release(raw) });
		if let Some(error) = listener_failure {
			return match release {
				Ok(()) => Err(error),
				Err(cleanup) => Err(error.with_secondary(cleanup)),
			};
		}
		release
	}
}

impl Drop for Netlayer<'_> {
	fn drop(&mut self) {
		if !self.raw.is_null() {
			if let Err(error) = check_onion(unsafe { ffi::pancake_onion_netlayer_release(self.raw) }) {
				let listener_failure = lock_failure(&self.listener_close_failure).take();
				crate::record_runtime_failure(
					crate::FailureLayer::Transport,
					"onion-netlayer-drop-release",
					listener_failure.map_or(error.clone(), |primary| primary.with_secondary(error)),
				);
			} else if let Some(error) = lock_failure(&self.listener_close_failure).take() {
				crate::record_runtime_failure(crate::FailureLayer::Transport, "onion-listener-drop-release", error);
			}
		}
	}
}

/// A live onion service: the control session keeping it published plus the local
/// endpoint Tor forwards it to.
///
/// Dropping it withdraws the service, so the address stops resolving. That is the
/// one release in this family with an effect a partner can observe.
pub struct Listener<'a> {
	raw: *mut ffi::PancakeOnionListener,
	id: [u8; ffi::ONION_SERVICE_ID_LEN],
	id_len: usize,
	key: [u8; ffi::ONION_SERVICE_KEY_CAP],
	key_len: usize,
	close_failure: Arc<Mutex<Option<Error>>>,
	_nl: PhantomData<&'a ()>,
}

impl Listener<'_> {
	/// The version 3 service id Tor minted or restored, without its `.onion`
	/// suffix. This is the designator a partner dials, and the one to put in an
	/// `ocapn://<id>.onion` locator.
	pub fn service_id(&self) -> &str {
		// The transport refuses any id that is not 56 base32 characters, so this
		// is ASCII by construction.
		core::str::from_utf8(&self.id[..self.id_len]).unwrap_or("")
	}

	/// The key that restores this exact service, or empty when the service was
	/// restored rather than minted. Store these bytes and pass them back as
	/// [`Config::with_service_key`] for an onion address that survives a restart.
	pub fn service_key(&self) -> &[u8] {
		&self.key[..self.key_len]
	}

	/// Block until Tor forwards a circuit to this service.
	///
	/// The partner's claimed location is unverified here: Tor tells a hidden
	/// service nothing about who dialed it.
	pub fn accept(&self, codec: Codec, max_frame_bytes: usize) -> Result<Connection<'_>> {
		let mut raw: *mut ffi::PancakeOnionConn = core::ptr::null_mut();
		check_onion(unsafe { ffi::pancake_onion_accept(self.raw, codec.to_c(), max_frame_bytes, &mut raw) })?;
		Ok(Connection { raw, _nl: PhantomData })
	}

	/// The descriptor this listener's circuits arrive on, for a caller that polls
	/// rather than blocks.
	///
	/// This is what keeps an event-driven consumer off the blocking path: register
	/// it with your reactor and call [`Listener::accept`] only once it is readable.
	/// An onion service's forward target is an ordinary local socket, which is why a
	/// real descriptor is available here rather than a synthesized readiness fd.
	///
	/// Owned by the listener: do not close it, and do not use it after the listener
	/// drops.
	pub fn readiness_fd(&self) -> Result<i32> {
		let mut fd: i32 = -1;
		check_onion(unsafe { ffi::pancake_onion_listener_readiness_fd(self.raw, &mut fd) })?;
		Ok(fd)
	}

	/// Wait up to `timeout_ms` for [`Listener::accept`] to be able to make
	/// progress. False on timeout.
	///
	/// This is what lets an accept loop check a stop flag instead of parking
	/// forever, without closing the listener from another thread.
	pub fn wait(&self, timeout_ms: i32) -> Result<bool> {
		let mut ready: core::ffi::c_uint = 0;
		check_onion(unsafe { ffi::pancake_onion_listener_wait(self.raw, timeout_ms, &mut ready) })?;
		Ok(ready != 0)
	}

	fn release(&mut self) -> Result<()> {
		if self.raw.is_null() {
			return Ok(());
		}
		let raw = core::mem::replace(&mut self.raw, core::ptr::null_mut());
		check_onion(unsafe { ffi::pancake_onion_listener_release(raw) })
	}

	/// Close explicitly and return the native teardown failure, if any.
	pub fn close(mut self) -> Result<()> {
		self.release()
	}
}

// SAFETY: a `Listener` owns a self-contained payload — its own control session,
// bound local endpoint, and a copy of the netlayer's allocator — and shares no
// per-handle mutable state with the netlayer or sibling handles, so moving it to
// the accepting thread and calling `accept` there touches only its own state. What
// it shares with the netlayer is thread-safe: the allocator and the
// `std.Io.Threaded` backend. Borrowing the netlayer keeps it non-`'static`, so
// callers move it into a scoped thread.
unsafe impl Send for Listener<'_> {}

impl Drop for Listener<'_> {
	fn drop(&mut self) {
		if let Err(error) = self.release() {
			let mut retained = lock_failure(&self.close_failure);
			if retained.is_none() {
				*retained = Some(error);
			}
		}
	}
}

/// A blocking onion connection, the `pancake_onion_*` frame shuttle. Closed on
/// drop. The frame methods block.
pub struct Connection<'a> {
	raw: *mut ffi::PancakeOnionConn,
	_nl: PhantomData<&'a ()>,
}

impl Connection<'_> {
	/// Seal this connection and interrupt blocking frame operations. Drop then
	/// releases its storage after callers have joined their operation threads.
	pub fn shutdown(&self) -> Result<()> {
		check_onion(unsafe { ffi::pancake_onion_conn_shutdown(self.raw) })
	}

	/// Close explicitly, reporting a shutdown failure to the caller. Native
	/// storage is released as this value is consumed; a release-only refusal is
	/// retained by the process diagnostic fallback because `Drop` has no caller.
	pub fn close(self) -> Result<()> {
		self.shutdown()
	}

	/// Block for one whole frame. [`ErrorKind::Closed`](crate::ErrorKind::Closed)
	/// reports a clean EOF.
	pub fn read_frame(&mut self) -> Result<Vec<u8>> {
		let mut frame: crate::sys::PancakeManagedFrame = unsafe { core::mem::zeroed() };
		check_onion(unsafe { ffi::pancake_onion_conn_read_frame(self.raw, &mut frame) })?;
		let out = unsafe { crate::owned_from_view(frame.bytes, frame.len) };
		unsafe { crate::sys::pancake_managed_frame_release(&mut frame) };
		Ok(out)
	}

	/// The descriptor this connection's bytes flow over, for a caller that polls
	/// rather than blocks. Same contract as [`Listener::readiness_fd`].
	pub fn readiness_fd(&self) -> Result<i32> {
		let mut fd: i32 = -1;
		check_onion(unsafe { ffi::pancake_onion_conn_readiness_fd(self.raw, &mut fd) })?;
		Ok(fd)
	}

	/// Write one frame's bytes to the partner.
	pub fn write_frame(&mut self, bytes: &[u8]) -> Result<()> {
		let f = crate::sys::PancakeFrame {
			bytes: bytes.as_ptr(),
			len: bytes.len(),
			shape: crate::sys::FRAME_SHAPE_BYTE,
		};
		check_onion(unsafe { ffi::pancake_onion_conn_write_frame(self.raw, &f) })
	}
}

// SAFETY: as `Listener` above — a `Connection` owns its own stream plus a copy of
// the netlayer's allocator, and the state it shares is thread-safe under the
// concurrent blocking calls a borrowed handle makes off-thread.
unsafe impl Send for Connection<'_> {}

impl Drop for Connection<'_> {
	fn drop(&mut self) {
		if let Err(error) = check_onion(unsafe { ffi::pancake_onion_conn_release(self.raw) }) {
			crate::record_runtime_failure(crate::FailureLayer::Transport, "onion-connection-drop-release", error);
		}
	}
}

#[cfg(feature = "async")]
/// A native-loop onion listener yielding ordinary high-level [`Session`]s.
///
/// The generic driver owns Tor execution, admission, and accepted-session
/// pumping. This type exposes only the driver's canonical locator and the
/// onion provider's opaque restoration key; it does not recreate either value
/// from configuration or from the public service id.
pub struct Server {
	listener: crate::server::LoopListener,
	service_key: Vec<u8>,
}

#[cfg(feature = "async")]
impl Server {
	async fn bind(config: Config<'_>, options: ListenOptions) -> Result<Self> {
		let owns_loop = !matches!(&options.identity, ListenerIdentity::Host(_));
		let host = options.identity.into_host()?;
		let shared = host.shared();
		let lp = shared.ensure_driver_loop(
			crate::session::HANDSHAKE_TIMEOUT.as_millis() as u32,
			crate::session::HANDSHAKE_TIMEOUT.as_millis() as u32,
		)?;
		Self::bind_on_loop(lp, host, config, owns_loop).await
	}

	async fn bind_on_loop(
		lp: Rc<crate::driver_loop::LoopShared>,
		host: crate::Host,
		config: Config<'_>,
		owns_loop: bool,
	) -> Result<Self> {
		let mut listener = None;
		let result = async {
			ensure_loop_provider(&lp, &config)?;
			let id = lp.listen(crate::abi_constants::TRANSPORT_ONION, "").await?;
			listener = Some(id);
			lp.select_listener(id)?;
			Ok::<_, crate::Error>(())
		}
		.await;
		if let Err(mut err) = result {
			if let Some(id) = listener {
				if let Err(cleanup) = lp.close_listener(id) {
					err = err.with_secondary(cleanup);
				}
			}
			if owns_loop {
				lp.close();
			}
			return Err(err);
		}
		let listener = listener.expect("onion listener is set after successful bind");

		let service_key = match lp.listener_restoration_state(listener) {
			Ok(key) => key,
			Err(err) => {
				let err = match lp.close_listener(listener) {
					Ok(()) => err,
					Err(cleanup) => err.with_secondary(cleanup),
				};
				if owns_loop {
					lp.close();
				}
				return Err(err);
			}
		};
		Ok(Self {
			listener: crate::server::LoopListener::new(Rc::clone(&lp), listener, host),
			service_key,
		})
	}

	/// The Host shared by every accepted session.
	pub fn host(&self) -> crate::Host {
		self.listener.host()
	}

	/// The driver's canonical OCapN locator for this listener.
	pub fn locator(&self) -> Result<crate::Locator> {
		self.listener.locator()
	}

	/// The driver's canonical OCapN locator rendered as a URI.
	pub fn uri(&self) -> Result<String> {
		crate::uri::format_locator_uri(&self.locator()?)
	}

	/// The onion service id in the driver's canonical locator.
	pub fn service_id(&self) -> Result<String> {
		Ok(self.locator()?.designator)
	}

	/// The provider-owned bytes needed to restore this exact Tor service.
	pub fn service_key(&self) -> &[u8] {
		&self.service_key
	}

	/// Accept the next partner as a ready high-level [`Session`].
	pub async fn accept(&self) -> Result<crate::Session> {
		self.listener.accept().await
	}

	/// Stop admitting partners. Already accepted sessions remain live on the
	/// shared Host, matching [`crate::tcp::Server`] and [`crate::iroh::Server`].
	pub fn close(&self) -> Result<()> {
		self.listener.close()
	}
}

#[cfg(feature = "async")]
/// Bind an onion service and return its high-level listener.
pub async fn listen(config: Config<'_>, options: ListenOptions) -> Result<Server> {
	Server::bind(config, options).await
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::io::{Read, Write};
	use std::net::{TcpListener, TcpStream};

	/// A real, checksum-valid version 3 id, from the pinned Goblins source. Using
	/// a well-formed one matters: the transport refuses anything else before it
	/// opens a socket, so a placeholder would pass these tests for the wrong
	/// reason.
	const SERVICE_ID: &str = "wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd";

	/// Answer one Tor control conversation: `AUTHENTICATE`, then `ADD_ONION`.
	///
	/// This is a fake, not a Tor. The bytes it accepts are pinned against the
	/// pinned Goblins netlayer and the upstream OCapN suite on the Zig side; here
	/// it only lets the binding's own surface be exercised with no daemon.
	/// Returns the `AUTHENTICATE` line it received, so a test can assert which
	/// credential form actually reached the daemon. Without that, a mapping that
	/// silently sent no credential would pass every other test here.
	fn fake_control(listener: TcpListener) -> String {
		fake_control_reporting(listener, None)
	}

	/// As `fake_control`, and when `forward` is given, send the forward target the
	/// `ADD_ONION` named down it. That target is the local endpoint pancake bound
	/// and told the daemon about, which is what a test needs to stand in for Tor
	/// forwarding a circuit.
	fn fake_control_reporting(listener: TcpListener, forward: Option<std::sync::mpsc::Sender<String>>) -> String {
		let mut authenticate = String::new();
		let (mut stream, _) = listener.accept().unwrap();
		let mut pending = Vec::new();
		let mut byte = [0u8; 1];
		loop {
			match stream.read(&mut byte) {
				Ok(0) | Err(_) => return authenticate,
				Ok(_) => {}
			}
			if byte[0] != b'\n' {
				if byte[0] != b'\r' {
					pending.push(byte[0]);
				}
				continue;
			}
			let line = String::from_utf8_lossy(&pending).to_string();
			pending.clear();
			if line.starts_with("AUTHENTICATE") {
				authenticate = line.clone();
			}
			if line.starts_with("ADD_ONION") {
				if let Some(tx) = forward.as_ref() {
					// `PORT=<virtual>,<target>` — the target is what follows the comma.
					if let Some(at) = line.find("PORT=") {
						if let Some(comma) = line[at..].find(',') {
							let _ = tx.send(line[at + comma + 1..].to_string());
						}
					}
				}
			}
			let reply = if line.starts_with("ADD_ONION") {
				format!("250-ServiceID={SERVICE_ID}\r\n250-PrivateKey=ED25519-V3:c3RvcmVk\r\n250 OK\r\n")
			} else {
				"250 OK\r\n".to_string()
			};
			if stream.write_all(reply.as_bytes()).is_err() {
				return authenticate;
			}
		}
	}

	/// Answer one SOCKS5 handshake for `SERVICE_ID` and return the stream, which
	/// is then an ordinary byte pipe — exactly what a circuit is once the reply is
	/// out.
	fn fake_socks(listener: TcpListener) -> TcpStream {
		let (mut stream, _) = listener.accept().unwrap();
		let mut greeting = [0u8; 3];
		stream.read_exact(&mut greeting).unwrap();
		assert_eq!(greeting, [0x05, 0x01, 0x00]);
		stream.write_all(&[0x05, 0x00]).unwrap();

		// Four header bytes, the length byte, the 62-character address, and the
		// two-byte port.
		let mut request = [0u8; 69];
		stream.read_exact(&mut request).unwrap();
		assert_eq!(&request[..5], &[0x05, 0x01, 0x00, 0x03, 62]);
		assert_eq!(&request[5..5 + 56], SERVICE_ID.as_bytes());
		assert_eq!(&request[5 + 56..5 + 62], b".onion");
		// 9045, big-endian.
		assert_eq!(&request[67..], &[0x23, 0x55]);

		stream.write_all(&[0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).unwrap();
		stream
	}

	fn loopback() -> (TcpListener, String) {
		let listener = TcpListener::bind("127.0.0.1:0").unwrap();
		let address = listener.local_addr().unwrap().to_string();
		(listener, address)
	}

	#[test]
	#[cfg(feature = "async")]
	fn high_level_listener_projects_driver_locator_and_restoration_key() {
		let (control_listener, control) = loopback();
		let daemon = std::thread::spawn(move || fake_control(control_listener));
		let runtime = tokio::runtime::Builder::new_current_thread()
			.enable_all()
			.build()
			.unwrap();
		let local = tokio::task::LocalSet::new();
		local.block_on(&runtime, async {
			let config = Config::dial_only("127.0.0.1:1").with_control(&control, Auth::None);
			let server = listen(config, ListenOptions::default()).await.unwrap();

			let locator = server.locator().unwrap();
			assert_eq!(locator.transport, "onion");
			assert_eq!(locator.designator, SERVICE_ID);
			assert!(locator.hints.is_empty());
			assert_eq!(server.service_id().unwrap(), SERVICE_ID);
			assert_eq!(server.uri().unwrap(), format!("ocapn://{SERVICE_ID}.onion"));
			assert_eq!(server.service_key(), b"ED25519-V3:c3RvcmVk");

			server.close().unwrap();
			let accepted = server.accept().await;
			assert_eq!(accepted.err().map(|err| err.code()), Some(crate::sys::ERR_CLOSED));
		});
		drop(runtime);
		assert_eq!(daemon.join().unwrap(), "AUTHENTICATE");
	}

	#[test]
	#[cfg(feature = "async")]
	fn caller_owned_host_survives_onion_listener_close() {
		let (control_listener, control) = loopback();
		let daemon = std::thread::spawn(move || fake_control(control_listener));
		let runtime = tokio::runtime::Builder::new_current_thread()
			.enable_all()
			.build()
			.unwrap();
		let local = tokio::task::LocalSet::new();
		local.block_on(&runtime, async {
			let host = crate::Host::from_seed([0x73; 32]).unwrap();
			let config = Config::dial_only("127.0.0.1:1").with_control(&control, Auth::None);
			let server = listen(
				config,
				ListenOptions {
					identity: ListenerIdentity::Host(host.clone()),
				},
			)
			.await
			.unwrap();
			server.close().unwrap();
			assert!(host.designator().is_ok());
			drop(server);
			host.close(crate::PendingWork::Cancel).await.unwrap();
		});
		drop(runtime);
		assert_eq!(daemon.join().unwrap(), "AUTHENTICATE");
	}

	#[test]
	#[cfg(feature = "async")]
	fn caller_owned_host_rejects_incompatible_onion_provider_config() {
		let (control_listener, control) = loopback();
		let daemon = std::thread::spawn(move || fake_control(control_listener));
		let runtime = tokio::runtime::Builder::new_current_thread()
			.enable_all()
			.build()
			.unwrap();
		let local = tokio::task::LocalSet::new();
		local.block_on(&runtime, async {
			let host = crate::Host::from_seed([0x74; 32]).unwrap();
			let config = Config::dial_only("127.0.0.1:1").with_control(&control, Auth::None);
			let server = listen(
				config,
				ListenOptions {
					identity: ListenerIdentity::Host(host.clone()),
				},
			)
			.await
			.unwrap();
			server.close().unwrap();

			let incompatible = Config::dial_only("127.0.0.1:1")
				.with_control(&control, Auth::None)
				.with_forward("127.0.0.1:2");
			let result = listen(
				incompatible,
				ListenOptions {
					identity: ListenerIdentity::Host(host.clone()),
				},
			)
			.await;
			assert_eq!(
				result.err().map(|err| err.code()),
				Some(crate::sys::ERR_INVALID_ARGUMENT)
			);

			host.close(crate::PendingWork::Cancel).await.unwrap();
		});
		drop(runtime);
		assert_eq!(daemon.join().unwrap(), "AUTHENTICATE");
	}

	#[test]
	#[cfg(feature = "async")]
	fn provider_registration_outlives_its_construction_reference() {
		let (control_listener, control) = loopback();
		let daemon = std::thread::spawn(move || fake_control(control_listener));
		let config = Config::dial_only("127.0.0.1:1").with_control(&control, Auth::None);
		let driver = crate::driver_loop::DriverLoop::open(
			&[0x71; 64],
			crate::driver_loop::DriverLoopOptions {
				handshake_ms: 1_000,
				settle_ms: 1_000,
				..crate::driver_loop::DriverLoopOptions::default()
			},
		)
		.unwrap();

		install_provider(&driver, &config).unwrap();
		assert!(driver.has_transport("onion").unwrap());
		let listener = driver.listen("onion", "").unwrap();
		'ready: for attempt in 0..1_000 {
			for event in driver.step(20).unwrap().unwrap_or_default() {
				match event {
					crate::driver_loop::LoopEvent::ListenerReady { listener: ready } if ready == listener => {
						break 'ready;
					}
					crate::driver_loop::LoopEvent::ListenerFailed {
						listener: failed,
						failure,
					} if failed == listener => panic!("listener failed: {}", failure.primary_name),
					_ => {}
				}
			}
			if attempt == 999 {
				panic!("listener setup timed out");
			}
		}
		let locator = driver.listener_locator(listener).unwrap();
		assert_eq!(locator.transport, "onion");
		assert_eq!(locator.designator, SERVICE_ID);
		driver.close_listener(listener).unwrap();
		drop(driver);
		assert_eq!(daemon.join().unwrap(), "AUTHENTICATE");
	}

	// A dial through the SOCKS endpoint carries a frame, proving the `onion`
	// archive composes with the core exactly as the tcp and inproc ones do.
	#[test]
	fn shuttles_a_frame_over_a_dialed_circuit() {
		// What reaches the wire is the frame inside its netstring envelope: a
		// Syrup byte string whose length prefix the reader strips again. Asserting
		// the framed form rather than the bare payload is what makes this a
		// transport proof instead of a memcpy proof.
		const PAYLOAD: &[u8] = b"<8'op:abort3\"bye>";
		let framed: Vec<u8> = format!("{}:", PAYLOAD.len())
			.into_bytes()
			.into_iter()
			.chain(PAYLOAD.iter().copied())
			.collect();

		let (socks_listener, socks) = loopback();
		let expected_len = framed.len();
		let far = std::thread::spawn(move || {
			let mut stream = fake_socks(socks_listener);
			let mut got = vec![0u8; expected_len];
			stream.read_exact(&mut got).unwrap();
			got
		});

		let netlayer = Netlayer::new(&Config::dial_only(&socks)).unwrap();
		let mut conn = netlayer.connect(SERVICE_ID, Codec::Syrup, 4096).unwrap();
		conn.write_frame(PAYLOAD).unwrap();

		assert_eq!(far.join().unwrap(), framed);
	}

	// Hosting reports the id the daemon named and the key that restores it.
	#[test]
	fn listening_reports_the_service_tor_named() {
		let (control_listener, control) = loopback();
		let daemon = std::thread::spawn(move || fake_control(control_listener));

		let config = Config::dial_only("127.0.0.1:1").with_control(&control, Auth::None);
		let netlayer = Netlayer::new(&config).unwrap();
		let listener = netlayer.listen().unwrap();

		assert_eq!(listener.service_id(), SERVICE_ID);
		assert_eq!(listener.service_key(), b"ED25519-V3:c3RvcmVk");
		// Nothing has dialed, so the wait expires rather than parking.
		assert!(!listener.wait(1).unwrap());

		drop(listener);
		drop(netlayer);
		assert_eq!(daemon.join().unwrap(), "AUTHENTICATE");
	}

	/// Drive one `listen` against a fake daemon and report the `AUTHENTICATE` line
	/// the daemon saw.
	fn authenticate_line_for(auth: Auth<'_>) -> String {
		let (control_listener, control) = loopback();
		let daemon = std::thread::spawn(move || fake_control(control_listener));
		let config = Config::dial_only("127.0.0.1:1").with_control(&control, auth);
		{
			let netlayer = Netlayer::new(&config).unwrap();
			let listener = netlayer.listen().unwrap();
			drop(listener);
		}
		daemon.join().unwrap()
	}

	// Each credential form reaches the daemon as its own request. This is the test
	// that catches a mapping which sends no credential at all: every other test
	// here uses an unauthenticated endpoint, where that mistake looks like success.
	#[test]
	fn each_auth_form_reaches_the_daemon_as_itself() {
		// Goblins' form: the bare keyword, no credential.
		assert_eq!(authenticate_line_for(Auth::None), "AUTHENTICATE");
		// A cookie file's bytes, as hexadecimal.
		assert_eq!(
			authenticate_line_for(Auth::Cookie(&[0x00, 0x01, 0x0f, 0xff])),
			"AUTHENTICATE 00010fff"
		);
		// A password, as a quoted string.
		assert_eq!(
			authenticate_line_for(Auth::Password("hunter2")),
			"AUTHENTICATE \"hunter2\""
		);
	}

	// The readiness descriptor is the point of the whole surface: it must be a real,
	// pollable socket that reports "nothing yet" before a partner arrives and
	// "readable" after one does. A test that only asserted the number was non-negative
	// would pass on a descriptor pointing at anything at all.
	#[test]
	fn the_listener_descriptor_reports_arrival_without_blocking() {
		let (control_listener, control) = loopback();
		let (tx, rx) = std::sync::mpsc::channel();
		let daemon = std::thread::spawn(move || fake_control_reporting(control_listener, Some(tx)));

		let config = Config::dial_only("127.0.0.1:1").with_control(&control, Auth::None);
		let netlayer = Netlayer::new(&config).unwrap();
		let listener = netlayer.listen().unwrap();
		let fd = listener.readiness_fd().unwrap();
		assert!(fd >= 0);

		// The descriptor must be the live accept socket, not merely a non-negative
		// number. Duplicating it and asking for a non-blocking accept proves both
		// halves: `WouldBlock` says it is a listening socket with nothing pending.
		// The duplicate is what keeps the listener's own descriptor intact.
		let probe = {
			use std::os::fd::{AsRawFd, BorrowedFd};
			let owned = unsafe { BorrowedFd::borrow_raw(fd) }.try_clone_to_owned().unwrap();
			let probe = TcpListener::from(owned);
			probe.set_nonblocking(true).unwrap();
			assert_eq!(probe.accept().unwrap_err().kind(), std::io::ErrorKind::WouldBlock);
			assert!(probe.as_raw_fd() != fd);
			probe
		};

		// Stand in for Tor forwarding a circuit: connect to the local endpoint the
		// listener bound and told the daemon about.
		let target = rx.recv().unwrap();
		let _circuit = TcpStream::connect(&target).unwrap();

		// Now readiness reports arrival on that same descriptor, and `accept`
		// returns instead of parking.
		assert!(listener.wait(1000).unwrap());
		let conn = listener.accept(Codec::Syrup, 4096).unwrap();
		// The connection has its own pollable descriptor too.
		assert!(conn.readiness_fd().unwrap() >= 0);

		drop(probe);
		drop(conn);
		drop(listener);
		drop(netlayer);
		let _ = daemon.join();
	}

	// A netlayer with no control endpoint can dial and cannot host, and says so
	// rather than reporting a service nothing could reach.
	#[test]
	fn a_dial_only_netlayer_refuses_to_host() {
		let netlayer = Netlayer::new(&Config::dial_only("127.0.0.1:1")).unwrap();
		// `Listener` is not `Debug` (an opaque handle), so match rather than
		// `unwrap_err`, and bind the code out so the temporary `Result` drops
		// before the netlayer it borrows.
		let code = match netlayer.listen() {
			Ok(_) => panic!("a dial-only netlayer should not host"),
			Err(err) => err.code(),
		};
		assert_ne!(code, crate::sys::OK);
	}

	// A designator that is not a well-formed version 3 address is refused before
	// any socket opens. The SOCKS endpoint here is a port nothing listens on, so a
	// check that ran later would report a connection failure instead.
	#[test]
	fn a_malformed_designator_is_refused_before_dialing() {
		let netlayer = Netlayer::new(&Config::dial_only("127.0.0.1:1")).unwrap();
		let code = match netlayer.connect("not-an-onion-address", Codec::Syrup, 4096) {
			Ok(_) => panic!("a malformed designator should be refused"),
			Err(err) => err.code(),
		};
		assert_ne!(code, crate::sys::OK);
	}
}
