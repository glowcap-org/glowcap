//! Relay archive provider composition for the async driver loop.
//!
//! One crate-private `Runtime` owns the archive runtime and installs one
//! provider package that advertises both `keyed-relay` and `noise-relay`. The
//! generic driver and Host select the profile. This module only owns
//! configuration and the archive lifetime, and [`provider`] is the one public
//! way to compose it.

use core::marker::PhantomData;

use crate::error_slot::error_slot;
use crate::sys::relay as ffi;
use crate::{HintValue, HintWireForm, Locator, Result};

pub use crate::ListenerIdentity;

error_slot!(
	fn check_relay;
	fn relay_last_error;
	ffi::glowcap_relay_last_error
);

fn require_archive() -> Result<()> {
	crate::require_archive_fingerprint(
		"relay",
		// SAFETY: `glowcap_relay_archive_fingerprint` takes no arguments and returns a scalar.
		unsafe { ffi::glowcap_relay_archive_fingerprint() },
		crate::abi_constants::RELAY_ARCHIVE_FINGERPRINT,
	)
}

fn profile_locator(transport: &str, designator: &str, relay_url: &str) -> Locator {
	let mut hints = std::collections::BTreeMap::new();
	hints.insert("rendezvous-relay".to_string(), HintValue::String(relay_url.to_string()));
	Locator {
		transport: transport.to_string(),
		designator: designator.to_string(),
		hints,
		hint_wire_form: HintWireForm::Map,
	}
}

fn route_from_locator(locator: &Locator) -> Result<&str> {
	if locator.transport != crate::TRANSPORT_KEYED_RELAY && locator.transport != crate::TRANSPORT_NOISE_RELAY {
		return Err(crate::Error::with_detail(
			crate::sys::ERR_INVALID_ARGUMENT,
			format!("relay provider cannot realize transport {:?}", locator.transport),
		));
	}
	locator.require_string_hint("rendezvous-relay")
}

/// Identity-addressed cleartext over the relay provider package.
pub mod keyed {
	use crate::Locator;

	pub fn locator(designator: &str, relay_url: &str) -> Locator {
		super::profile_locator(crate::TRANSPORT_KEYED_RELAY, designator, relay_url)
	}

	/// Register the identity-addressed cleartext relay profile and accept
	/// sessions. See [`super::noise::listen`]. Only the channel differs, and
	/// the relay path is not sealed.
	pub async fn listen(
		relay_url: &str,
		register_url: &str,
		options: super::ListenOptions<'_>,
	) -> crate::Result<super::Server> {
		super::listen_relay_profile(crate::TRANSPORT_KEYED_RELAY, relay_url, register_url, options).await
	}
}

/// Noise_XK-sealed streams over the relay provider package.
pub mod noise {
	use crate::Locator;

	pub fn locator(designator: &str, relay_url: &str) -> Locator {
		super::profile_locator(crate::TRANSPORT_NOISE_RELAY, designator, relay_url)
	}

	/// Register this listener's durable key at the relay and accept
	/// Noise_XK-sealed sessions. The relay archive's provider holds the
	/// registration socket. The driver owns admission, handshakes, and
	/// session lifetime. The driver's provider registry holds one relay
	/// configuration per loop: a second listen naming the same routes rides
	/// the installed provider, and one naming different routes is refused.
	pub async fn listen(
		relay_url: &str,
		register_url: &str,
		options: super::ListenOptions<'_>,
	) -> crate::Result<super::Server> {
		super::listen_relay_profile(crate::TRANSPORT_NOISE_RELAY, relay_url, register_url, options).await
	}
}

/// Relay listener construction options. The identity is a sum rather than two
/// optional fields, so conflicting seed and Host authority is unrepresentable.
#[derive(Clone, Default)]
pub struct ListenOptions<'a> {
	pub identity: crate::ListenerIdentity,
	/// Trust used when the registration or relay route selects WSS.
	pub trust: Trust<'a>,
}

/// A registered relay listener, the relay sibling of [`crate::tcp::Server`].
/// The FFI driver loop owns the registration socket, admission, and every
/// accepted session. This type is only the public listener view.
pub struct Server {
	listener: crate::server::LoopListener,
}

impl Server {
	/// Accept the next partner as a ready [`crate::Session`], sharing this
	/// server's [`crate::Host`]. Must be called inside a `LocalSet` (the
	/// handle graph is `!Send`).
	/// Await the next accepted session. It delivers its partner's inbound only
	/// once served: publish what it should answer, then `session.serve()`.
	pub async fn accept(&self) -> crate::Result<crate::Session> {
		self.listener.accept().await
	}

	/// The canonical locator advertised by this server.
	pub fn locator(&self) -> crate::Result<crate::Locator> {
		self.listener.locator()
	}

	/// The canonical `ocapn://` URI advertised by this server.
	pub fn uri(&self) -> crate::Result<String> {
		crate::uri::format_locator_uri(&self.locator()?)
	}

	/// This server's [`crate::Host`]: one retained identity and session
	/// directory across every accepted session.
	pub fn host(&self) -> crate::Host {
		self.listener.host()
	}

	/// Select this listener's locator as the shared Host's advertised
	/// location. See [`crate::tcp::Server::select`].
	pub fn select(&self) -> crate::Result<()> {
		self.listener.select()
	}

	/// Stop admitting partners. Sessions already returned by
	/// [`Server::accept`] remain live.
	pub async fn close(&self) -> crate::Result<()> {
		self.listener.close().await
	}
}

async fn listen_relay_profile(
	transport: &'static str,
	relay_url: &str,
	register_url: &str,
	options: ListenOptions<'_>,
) -> crate::Result<Server> {
	let config = Config {
		relay_url,
		register_url: Some(register_url),
		trust: options.trust,
		relay_alias_url: None,
	};
	// The provider registers as the listener opens, so a completed open is
	// the commit point: the relay answered and holds this peer's sockets. The
	// relay routes by the Host's durable key, so the listener binds an empty
	// designator and needs nothing from the open listener beyond its handle.
	let (listener, ()) = crate::server::bind_loop_listener(
		options.identity,
		transport,
		|_host, lp| std::future::ready(install_provider(&lp, config).map(|()| (String::new(), ()))),
		|_lp, _listener, _designator, ()| Ok(()),
	)
	.await?;
	Ok(Server { listener })
}

/// Immutable trust snapshot used by the relay archive's TLS carrier.
#[derive(Clone, Copy, Debug, Default)]
pub enum Trust<'a> {
	/// Load the process platform's trust roots once during construction.
	#[default]
	System,
	/// Copy one PEM snapshot during construction. The runtime retains no borrow.
	CopiedPem(&'a [u8]),
}

/// URLs and trust used to construct the shared relay archive provider. status-allow: purpose clause
#[derive(Clone, Copy, Debug)]
pub struct Config<'a> {
	/// The relay WebSocket URL used for outbound keyed/noise legs.
	pub relay_url: &'a str,
	/// The registration URL used when listening. `None` makes this provider
	/// dial-only. The driver still advertises both profiles.
	pub register_url: Option<&'a str>,
	/// Trust used when any validated route selects WSS.
	pub trust: Trust<'a>,
	/// Redirect this exact advertised dial route to `relay_url`. Both routes
	/// must reach the same registry. Other peers retain their advertised route.
	pub relay_alias_url: Option<&'a str>,
}

impl<'a> Config<'a> {
	pub const fn dial_only(relay_url: &'a str) -> Self {
		Self {
			relay_url,
			register_url: None,
			trust: Trust::System,
			relay_alias_url: None,
		}
	}

	pub const fn with_trust(mut self, trust: Trust<'a>) -> Self {
		self.trust = trust;
		self
	}

	pub const fn with_relay_alias(mut self, alias: &'a str) -> Self {
		self.relay_alias_url = Some(alias);
		self
	}

	fn to_c(self) -> ffi::GlowcapRelayConfig {
		let register = self.register_url.unwrap_or("");
		let alias = self.relay_alias_url.unwrap_or("");
		let (trust, trust_pem, trust_pem_len) = match self.trust {
			Trust::System => (ffi::GLOWCAP_RELAY_TRUST_SYSTEM, core::ptr::null(), 0),
			Trust::CopiedPem(pem) => (ffi::GLOWCAP_RELAY_TRUST_COPIED_PEM, pem.as_ptr(), pem.len()),
		};
		ffi::GlowcapRelayConfig {
			abi_version: ffi::GLOWCAP_RELAY_CONFIG_ABI_VERSION,
			struct_size: core::mem::size_of::<ffi::GlowcapRelayConfig>(),
			relay_url: self.relay_url.as_ptr(),
			relay_url_len: self.relay_url.len(),
			register_url: register.as_ptr(),
			register_url_len: register.len(),
			trust,
			trust_pem,
			trust_pem_len,
			relay_alias_url: alias.as_ptr(),
			relay_alias_url_len: alias.len(),
		}
	}
}

/// Owns one relay provider runtime for the window between construction and
/// provider installation. It has no connection children because the FFI
/// driver owns all connection and listener handles after registration, and it
/// stays crate-private because [`provider`] and the listen spine are the only
/// composers of that lease.
pub(crate) struct Runtime {
	raw: *mut ffi::GlowcapRelayRuntime,
}

impl Runtime {
	pub(crate) fn new(config: Config<'_>) -> Result<Self> {
		require_archive()?;
		let c = config.to_c();
		let mut raw = core::ptr::null_mut();
		// SAFETY: `c` is the local `GlowcapRelayConfig` from `config.to_c()`, whose URL and PEM views borrow `config`'s
		// strings for the whole call, and the callee copies the configuration; `raw` is a local out-parameter the
		// callee fills with the new runtime handle.
		check_relay(unsafe { ffi::glowcap_relay_runtime_new(&c, &mut raw) })?;
		Ok(Self { raw })
	}

	pub(crate) fn transport_provider(&self) -> Result<crate::driver_loop::ProviderPackage<'_>> {
		// SAFETY: `GlowcapTransportProvider` is a plain C struct of integers and null pointers; all-zero is a valid
		// value, and `glowcap_relay_transport_provider` fills it before it is read.
		let mut package = unsafe { core::mem::zeroed() };
		// SAFETY: `self.raw` is this `Runtime`'s handle from `glowcap_relay_runtime_new`, released only by `close` or
		// `Drop`; `package` is a local out-parameter the callee fills, and the returned `ProviderPackage` borrows
		// `self` so the handle outlives it.
		check_relay(unsafe { ffi::glowcap_relay_transport_provider(self.raw, &mut package) })?;
		Ok(crate::driver_loop::ProviderPackage {
			package,
			_owner: PhantomData,
		})
	}

	/// Consume the constructor lease and report the FFI teardown barrier.
	/// After provider installation this normally releases only that lease. The
	/// driver reports final asynchronous teardown when it closes.
	pub(crate) fn close(mut self) -> Result<()> {
		let raw = core::mem::replace(&mut self.raw, core::ptr::null_mut());
		// SAFETY: `raw` is this `Runtime`'s handle from `glowcap_relay_runtime_new`, taken out of `self` above so
		// `Drop` will not release it again; the three null and zero diagnostic arguments omit the error capture.
		check_relay(unsafe { ffi::glowcap_relay_runtime_release(raw, core::ptr::null_mut(), 0, core::ptr::null_mut()) })
	}
}

impl Drop for Runtime {
	fn drop(&mut self) {
		if !self.raw.is_null()
			// SAFETY: `self.raw` is this `Runtime`'s non-null handle (checked above) from `glowcap_relay_runtime_new`;
			// `Drop` runs once and `close` has nulled the field when it released first, and the three null and zero
			// diagnostic arguments omit the error capture.
			&& let Err(error) = check_relay(unsafe {
				ffi::glowcap_relay_runtime_release(self.raw, core::ptr::null_mut(), 0, core::ptr::null_mut())
			}) {
			crate::record_runtime_failure(crate::FailureLayer::Transport, "relay-runtime-drop-release", error);
		}
	}
}

/// Install the shared keyed-relay/noise-relay package into the loop, then
/// release the constructor lease: the driver's provider lease is the
/// runtime's lifetime authority from here on.
fn install_provider(lp: &crate::driver_loop::LoopShared, config: Config<'_>) -> Result<()> {
	let runtime = Runtime::new(config)?;
	let installed = (|| {
		let package = runtime.transport_provider()?;
		lp.add_provider(package)
	})();
	match installed {
		Ok(()) => runtime.close(),
		Err(primary) => Err(crate::retain_cleanup_failure(primary, runtime.close())),
	}
}

/// Configure this archive's keyed-relay/noise-relay package for a generic
/// [`crate::Runtime::connect`] operation.
pub fn provider(config: Config<'_>) -> crate::driver_loop::Provider {
	let relay_url = config.relay_url.to_owned();
	let register_url = config.register_url.map(str::to_owned);
	let relay_alias_url = config.relay_alias_url.map(str::to_owned);
	let trust_pem = match config.trust {
		Trust::System => None,
		Trust::CopiedPem(pem) => Some(pem.to_vec()),
	};
	crate::driver_loop::Provider::new(move |lp| {
		let relay_url = relay_url.clone();
		let register_url = register_url.clone();
		let relay_alias_url = relay_alias_url.clone();
		let trust_pem = trust_pem.clone();
		async move {
			install_provider(
				&lp,
				Config {
					relay_url: &relay_url,
					register_url: register_url.as_deref(),
					trust: trust_pem.as_deref().map_or(Trust::System, Trust::CopiedPem),
					relay_alias_url: relay_alias_url.as_deref(),
				},
			)
		}
	})
}

/// Configure a dial-only FFI provider from a routed relay locator.
/// Locator interpretation remains in this transport package rather than the
/// generic dial path or application.
pub fn provider_for(locator: &Locator) -> Result<crate::driver_loop::Provider> {
	Ok(provider(Config::dial_only(route_from_locator(locator)?)))
}

#[cfg(test)]
mod tests {
	use super::{Config, Trust};

	#[test]
	fn system_trust_has_the_c_contracts_empty_view() {
		let raw = Config::dial_only("wss://relay.example/relay").to_c();
		assert!(raw.trust_pem.is_null());
		assert_eq!(raw.trust_pem_len, 0);
	}

	#[test]
	fn copied_trust_preserves_its_borrowed_view() {
		let pem = b"fixture pem";
		let raw = Config::dial_only("wss://relay.example/relay")
			.with_trust(Trust::CopiedPem(pem))
			.to_c();
		assert_eq!(raw.trust_pem, pem.as_ptr());
		assert_eq!(raw.trust_pem_len, pem.len());
	}
}
