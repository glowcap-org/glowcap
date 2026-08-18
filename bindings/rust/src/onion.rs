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

fn require_archive() -> Result<()> {
	crate::require_archive_fingerprint(
		"onion",
		unsafe { ffi::pancake_onion_archive_fingerprint() },
		crate::abi_constants::ONION_ARCHIVE_FINGERPRINT,
	)
}

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
/// Connections and listeners borrow it, so neither can outlive the netlayer
/// that produced it. The context lifetime also pins context-backed storage.
pub struct Netlayer<'ctx> {
	raw: *mut ffi::PancakeOnionNetlayer,
	listener_close_failure: Arc<Mutex<Option<Error>>>,
	_ctx: PhantomData<&'ctx Context>,
}

/// A live onion service and the control session that keeps it published.
pub struct Listener<'a> {
	raw: *mut ffi::PancakeOnionListener,
	id: [u8; ffi::ONION_SERVICE_ID_LEN],
	id_len: usize,
	key: [u8; ffi::ONION_SERVICE_KEY_CAP],
	key_len: usize,
	close_failure: Arc<Mutex<Option<Error>>>,
	_nl: PhantomData<&'a ()>,
}

/// A blocking onion connection. The frame methods block and drop closes it.
pub struct Connection<'a> {
	raw: *mut ffi::PancakeOnionConn,
	_nl: PhantomData<&'a ()>,
}

mod blocking;

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
#[path = "onion/tests.rs"]
mod tests;
