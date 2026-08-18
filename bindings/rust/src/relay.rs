//! Native relay provider composition for the async driver loop.
//!
//! One [`Runtime`] owns the archive runtime and installs one provider package
//! that advertises both `keyed-relay` and `noise-relay`. The generic driver and
//! Host select the profile; this module only owns configuration and the archive
//! lifetime.

use core::marker::PhantomData;

use crate::error_slot::error_slot;
use crate::sys::relay as ffi;
use crate::{Context, HintValue, HintWireForm, Locator, Result};

error_slot!(
	fn check_relay;
	fn relay_last_error;
	ffi::pancake_relay_last_error
);

fn require_archive() -> Result<()> {
	crate::require_archive_fingerprint(
		"relay",
		unsafe { ffi::pancake_relay_archive_fingerprint() },
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
	locator
		.string_hint("rendezvous-relay")?
		.filter(|route| !route.is_empty())
		.ok_or_else(|| {
			crate::Error::with_detail(
				crate::sys::ERR_INVALID_ARGUMENT,
				"relay locator requires a non-empty rendezvous-relay hint".to_string(),
			)
		})
}

/// Identity-addressed cleartext over the relay provider package.
pub mod keyed {
	use crate::Locator;

	pub fn locator(designator: &str, relay_url: &str) -> Locator {
		super::profile_locator(crate::TRANSPORT_KEYED_RELAY, designator, relay_url)
	}
}

/// Noise_XK-sealed streams over the relay provider package.
pub mod noise {
	use crate::Locator;

	pub fn locator(designator: &str, relay_url: &str) -> Locator {
		super::profile_locator(crate::TRANSPORT_NOISE_RELAY, designator, relay_url)
	}
}

/// Immutable trust snapshot used by the native secure relay carrier.
#[derive(Clone, Copy, Debug, Default)]
pub enum Trust<'a> {
	/// Load the process platform's trust roots once during construction.
	#[default]
	System,
	/// Copy one PEM snapshot during construction. The runtime retains no borrow.
	CopiedPem(&'a [u8]),
}

/// URLs and trust used to construct the shared native relay provider.
#[derive(Clone, Copy, Debug)]
pub struct Config<'a> {
	/// The relay WebSocket URL used for outbound keyed/noise legs.
	pub relay_url: &'a str,
	/// The registration URL used when listening. `None` makes this provider
	/// dial-only; the driver still advertises both profiles.
	pub register_url: Option<&'a str>,
	/// Trust used when any validated route selects WSS.
	pub trust: Trust<'a>,
}

impl<'a> Config<'a> {
	pub const fn dial_only(relay_url: &'a str) -> Self {
		Self {
			relay_url,
			register_url: None,
			trust: Trust::System,
		}
	}

	pub const fn with_register_url(mut self, register_url: &'a str) -> Self {
		self.register_url = Some(register_url);
		self
	}

	pub const fn with_trust(mut self, trust: Trust<'a>) -> Self {
		self.trust = trust;
		self
	}

	fn to_c(self) -> ffi::PancakeRelayConfig {
		let register = self.register_url.unwrap_or("");
		let (trust, trust_pem, trust_pem_len) = match self.trust {
			Trust::System => (ffi::PANCAKE_RELAY_TRUST_SYSTEM, core::ptr::null(), 0),
			Trust::CopiedPem(pem) => (ffi::PANCAKE_RELAY_TRUST_COPIED_PEM, pem.as_ptr(), pem.len()),
		};
		ffi::PancakeRelayConfig {
			abi_version: ffi::PANCAKE_RELAY_CONFIG_ABI_VERSION,
			struct_size: core::mem::size_of::<ffi::PancakeRelayConfig>(),
			relay_url: self.relay_url.as_ptr(),
			relay_url_len: self.relay_url.len(),
			register_url: register.as_ptr(),
			register_url_len: register.len(),
			trust,
			trust_pem,
			trust_pem_len,
		}
	}
}

/// Immutable result of loading the native relay's trust snapshot.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TrustSummary {
	pub loaded: usize,
	pub skipped_by_engine: usize,
	pub first_skipped_engine_code: Option<i32>,
}

/// Owns one relay provider runtime. It has no connection children because the
/// native driver owns all connection and listener handles after registration.
pub struct Runtime<'ctx> {
	raw: *mut ffi::PancakeRelayRuntime,
	_ctx: PhantomData<&'ctx Context>,
}

impl<'ctx> Runtime<'ctx> {
	pub fn new(config: Config<'_>) -> Result<Self> {
		require_archive()?;
		let c = config.to_c();
		let mut raw = core::ptr::null_mut();
		check_relay(unsafe { ffi::pancake_relay_runtime_new(&c, &mut raw) })?;
		Ok(Self { raw, _ctx: PhantomData })
	}

	pub fn new_in(context: &'ctx Context, config: Config<'_>) -> Result<Self> {
		require_archive()?;
		let c = config.to_c();
		let mut raw = core::ptr::null_mut();
		check_relay(unsafe { ffi::pancake_relay_runtime_new_in(context.raw(), &c, &mut raw) })?;
		Ok(Self { raw, _ctx: PhantomData })
	}

	pub(crate) fn transport_provider(&self) -> Result<crate::driver_loop::ProviderPackage<'_>> {
		let mut package = unsafe { core::mem::zeroed() };
		check_relay(unsafe { ffi::pancake_relay_transport_provider(self.raw, &mut package) })?;
		Ok(crate::driver_loop::ProviderPackage {
			package,
			_owner: PhantomData,
		})
	}

	pub fn trust_summary(&self) -> Result<TrustSummary> {
		let mut raw = ffi::PancakeRelayTrustSummary::default();
		check_relay(unsafe { ffi::pancake_relay_runtime_trust_summary(self.raw, &mut raw) })?;
		Ok(TrustSummary {
			loaded: raw.loaded,
			skipped_by_engine: raw.skipped_by_engine,
			first_skipped_engine_code: (raw.first_skipped_engine_code != 0).then_some(raw.first_skipped_engine_code),
		})
	}

	/// Consume the constructor lease and report the native teardown barrier.
	/// After provider installation this normally releases only that lease; the
	/// driver reports final asynchronous teardown when it closes.
	pub fn close(mut self) -> Result<()> {
		let raw = core::mem::replace(&mut self.raw, core::ptr::null_mut());
		check_relay(unsafe { ffi::pancake_relay_runtime_release(raw, core::ptr::null_mut(), 0, core::ptr::null_mut()) })
	}
}

impl Drop for Runtime<'_> {
	fn drop(&mut self) {
		if !self.raw.is_null() {
			if let Err(error) = check_relay(unsafe {
				ffi::pancake_relay_runtime_release(self.raw, core::ptr::null_mut(), 0, core::ptr::null_mut())
			}) {
				crate::record_runtime_failure(crate::FailureLayer::Transport, "relay-runtime-drop-release", error);
			}
		}
	}
}

/// Install the shared keyed-relay/noise-relay package into a native driver.
pub fn install_provider(driver: &crate::driver_loop::DriverLoop, config: Config<'_>) -> Result<()> {
	let runtime = Runtime::new(config)?;
	let installed = (|| {
		let package = runtime.transport_provider()?;
		driver.add_provider(package)
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
	let trust_pem = match config.trust {
		Trust::System => None,
		Trust::CopiedPem(pem) => Some(pem.to_vec()),
	};
	crate::driver_loop::Provider::new(move |lp| {
		let relay_url = relay_url.clone();
		let register_url = register_url.clone();
		let trust_pem = trust_pem.clone();
		async move {
			let runtime = Runtime::new(Config {
				relay_url: &relay_url,
				register_url: register_url.as_deref(),
				trust: trust_pem.as_deref().map_or(Trust::System, Trust::CopiedPem),
			})?;
			let installed = (|| {
				let package = runtime.transport_provider()?;
				lp.add_provider(package)
			})();
			match installed {
				Ok(()) => runtime.close(),
				Err(primary) => Err(crate::retain_cleanup_failure(primary, runtime.close())),
			}
		}
	})
}

/// Configure a dial-only native provider from a routed relay locator.
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
