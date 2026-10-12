//! Thin projection of the driver's versioned deterministic failure record.
//!
//! Provider registration, listener close, and the consuming loop-release
//! barrier cannot use a thread-local text slot as their machine contract:
//! release destroys the owner, and rollback may add a second exact cause. This
//! module owns the one Rust projection of that fixed C record, which
//! `driver_loop::handle` fills through the loop it owns. Policy remains native.

use crate::sys::driver::GlowcapDriverFailure;
use crate::{Error, Result};

pub(crate) fn empty() -> GlowcapDriverFailure {
	GlowcapDriverFailure {
		abi_version: crate::sys::DRIVER_FAILURE_ABI_VERSION,
		struct_size: core::mem::size_of::<GlowcapDriverFailure>(),
		primary_result: crate::sys::OK,
		secondary_result: crate::sys::OK,
		secondary_count: 0,
		carrier_phase: crate::abi_constants_gen::CARRIER_PHASE_NONE,
		carrier_detail_flags: 0,
		carrier_verification_flags: 0,
		carrier_peer_alert: 0,
		carrier_engine_code: 0,
		primary_name: core::ptr::null(),
		primary_name_len: 0,
		secondary_name: core::ptr::null(),
		secondary_name_len: 0,
	}
}

unsafe fn name(ptr: *const u8, len: usize, field: &str) -> Result<String> {
	if len == 0 {
		return Ok(String::new());
	}
	if ptr.is_null() {
		return Err(Error::with_detail(
			crate::sys::ERR_INTERNAL,
			format!("driver returned null {field} with nonzero length"),
		));
	}
	// SAFETY: `ptr` is non-null (checked above) and names `len` bytes of a failure name the driver wrote into its
	// `GlowcapDriverFailure`, which the header documents as borrowed for the process lifetime; `to_owned` copies the
	// text before this function returns.
	let bytes = unsafe { core::slice::from_raw_parts(ptr, len) };
	let text = core::str::from_utf8(bytes)
		.map_err(|_| Error::with_detail(crate::sys::ERR_INTERNAL, format!("driver returned non-UTF-8 {field}")))?;
	Ok(text.to_owned())
}

pub(crate) fn decode(code: i32, raw: GlowcapDriverFailure, operation: &str) -> Result<()> {
	let carrier = crate::carrier_failure::decode(
		raw.carrier_phase,
		raw.carrier_detail_flags,
		raw.carrier_verification_flags,
		raw.carrier_peer_alert,
		raw.carrier_engine_code,
	)?;
	// SAFETY: `raw.primary_name` and `raw.primary_name_len` are the pair the driver filled in the
	// `GlowcapDriverFailure` the caller owns, or the null and zero `empty()` set, and `name` copies the
	// process-lifetime text into an owned `String`.
	let primary = unsafe { name(raw.primary_name, raw.primary_name_len, "primary failure name")? };
	// SAFETY: as `primary` above for `raw.secondary_name` and `raw.secondary_name_len`.
	let secondary = unsafe { name(raw.secondary_name, raw.secondary_name_len, "secondary failure name")? };
	if code == crate::sys::OK {
		if raw.primary_result == crate::sys::OK
			&& raw.secondary_result == crate::sys::OK
			&& raw.secondary_count == 0
			&& carrier.is_none()
			&& primary.is_empty()
			&& secondary.is_empty()
		{
			return Ok(());
		}
		return Err(Error::with_detail(
			crate::sys::ERR_INTERNAL,
			format!("{operation} returned success with failure data"),
		));
	}
	if raw.primary_result != code || primary.is_empty() {
		return Err(Error::with_detail(
			crate::sys::ERR_INTERNAL,
			format!("{operation} returned an inconsistent failure record"),
		));
	}
	if (raw.secondary_count == 0 && (raw.secondary_result != crate::sys::OK || !secondary.is_empty()))
		|| (raw.secondary_count != 0 && (raw.secondary_result == crate::sys::OK || secondary.is_empty()))
	{
		return Err(Error::with_detail(
			crate::sys::ERR_INTERNAL,
			format!("{operation} returned an inconsistent secondary failure"),
		));
	}
	let mut error = Error::with_detail(code, format!("{operation}: {primary}")).with_carrier_failure(carrier);
	if raw.secondary_count != 0 {
		error = error.with_secondary(Error::with_detail(raw.secondary_result, secondary));
		error.secondary_count = raw.secondary_count;
	}
	Err(error)
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn exact_primary_and_counted_secondary_survive_projection() {
		let primary = b"ProviderConfigurationConflict";
		let secondary = b"PackageReleaseFailed";
		let mut raw = empty();
		raw.primary_result = crate::sys::ERR_INVALID_ARGUMENT;
		raw.primary_name = primary.as_ptr();
		raw.primary_name_len = primary.len();
		raw.secondary_result = crate::sys::ERR_IO;
		raw.secondary_count = 3;
		raw.secondary_name = secondary.as_ptr();
		raw.secondary_name_len = secondary.len();
		raw.carrier_phase = crate::abi_constants_gen::CARRIER_PHASE_SECURE_HANDSHAKE;
		raw.carrier_detail_flags =
			crate::abi_constants_gen::CARRIER_DETAIL_PEER_ALERT | crate::abi_constants_gen::CARRIER_DETAIL_ENGINE_CODE;
		raw.carrier_verification_flags = 0x21;
		raw.carrier_peer_alert = 42;
		raw.carrier_engine_code = -0x2700;
		let error = decode(raw.primary_result, raw, "install").unwrap_err();
		assert_eq!(error.code(), crate::sys::ERR_INVALID_ARGUMENT);
		assert_eq!(error.message(), Some("install: ProviderConfigurationConflict"));
		assert_eq!(error.secondary_error_count(), 3);
		assert_eq!(error.secondary_errors()[0].message(), Some("PackageReleaseFailed"));
		assert_eq!(
			error.carrier_failure().unwrap().phase,
			crate::CarrierPhase::SecureHandshake
		);
		assert_eq!(error.carrier_failure().unwrap().peer_alert, Some(42));
		assert_eq!(error.carrier_failure().unwrap().engine_code, Some(-0x2700));
	}
}
