//! Native relay provider composition for the async driver loop.
//!
//! One [`Runtime`] owns the archive runtime and installs one provider package
//! that advertises both `keyed-relay` and `noise-relay`. The generic driver and
//! Host select the profile; this module only owns configuration and the archive
//! lifetime.

use core::marker::PhantomData;

use crate::error_slot::error_slot;
use crate::sys::relay as ffi;
use crate::{Context, Result};

error_slot!(
	fn check_relay;
	fn relay_last_error;
	ffi::pancake_relay_last_error
);

/// URLs used to construct the shared native relay provider.
#[derive(Clone, Copy, Debug)]
pub struct Config<'a> {
	/// The relay WebSocket URL used for outbound keyed/noise legs.
	pub relay_url: &'a str,
	/// The registration URL used when listening. `None` makes this provider
	/// dial-only; the driver still advertises both profiles.
	pub register_url: Option<&'a str>,
}

impl<'a> Config<'a> {
	pub const fn dial_only(relay_url: &'a str) -> Self {
		Self {
			relay_url,
			register_url: None,
		}
	}

	pub const fn with_register_url(mut self, register_url: &'a str) -> Self {
		self.register_url = Some(register_url);
		self
	}

	fn to_c(self) -> ffi::PancakeRelayConfig {
		let register = self.register_url.unwrap_or("");
		ffi::PancakeRelayConfig {
			relay_url: self.relay_url.as_ptr(),
			relay_url_len: self.relay_url.len(),
			register_url: register.as_ptr(),
			register_url_len: register.len(),
		}
	}
}

/// Owns one relay provider runtime. It has no connection children because the
/// native driver owns all connection and listener handles after registration.
pub struct Runtime<'ctx> {
	raw: *mut ffi::PancakeRelayRuntime,
	_ctx: PhantomData<&'ctx Context>,
}

impl<'ctx> Runtime<'ctx> {
	pub fn new(config: Config<'_>) -> Result<Self> {
		let c = config.to_c();
		let mut raw = core::ptr::null_mut();
		check_relay(unsafe { ffi::pancake_relay_runtime_new(&c, &mut raw) })?;
		Ok(Self {
			raw,
			_ctx: PhantomData,
		})
	}

	pub fn new_in(context: &'ctx Context, config: Config<'_>) -> Result<Self> {
		let c = config.to_c();
		let mut raw = core::ptr::null_mut();
		check_relay(unsafe { ffi::pancake_relay_runtime_new_in(context.raw(), &c, &mut raw) })?;
		Ok(Self {
			raw,
			_ctx: PhantomData,
		})
	}

	pub(crate) fn transport_provider(&self) -> Result<crate::driver_loop::TransportProvider<'_>> {
		let mut package = unsafe { core::mem::zeroed() };
		check_relay(unsafe { ffi::pancake_relay_transport_provider(self.raw, &mut package) })?;
		Ok(crate::driver_loop::TransportProvider {
			package,
			_owner: PhantomData,
		})
	}
}

impl Drop for Runtime<'_> {
	fn drop(&mut self) {
		unsafe { ffi::pancake_relay_runtime_release(self.raw) };
	}
}

/// Install the shared keyed-relay/noise-relay package into a native driver.
pub fn install_provider(driver: &crate::driver_loop::DriverLoop, config: Config<'_>) -> Result<()> {
	if driver.has_transport(crate::abi_constants::TRANSPORT_KEYED_RELAY)? {
		return Ok(());
	}
	let runtime = Runtime::new(config)?;
	driver.add_provider(runtime.transport_provider()?)
}

pub(crate) fn ensure_loop_provider(
	loop_shared: &crate::driver_loop::LoopShared,
	route: &str,
) -> Result<()> {
	if loop_shared.has_transport(crate::abi_constants::TRANSPORT_KEYED_RELAY)? {
		return Ok(());
	}
	let runtime = Runtime::new(Config::dial_only(route))?;
	loop_shared.add_provider(runtime.transport_provider()?)
}
