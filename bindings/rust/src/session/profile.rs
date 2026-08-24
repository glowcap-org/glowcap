use super::Session;
use crate::host::check_host;
use crate::sys;
use crate::sys::host as ffi;
use crate::{CaptpVersion, Codec, Error, FeatureSet, Result, SessionProfile};

impl Session {
	/// The exact netlayer symbol this connection was opened through.
	pub fn transport_name(&self) -> Result<String> {
		self.shared.guard_open()?;
		let mut ptr = core::ptr::null();
		let mut len = 0;
		check_host(unsafe { ffi::pancake_host_session_transport_name(self.shared.ptr.get(), &mut ptr, &mut len) })?;
		let bytes = unsafe { core::slice::from_raw_parts(ptr, len) };
		let text = core::str::from_utf8(bytes).map_err(|error| {
			Error::with_detail(
				sys::ERR_INTERNAL,
				format!("pancake ABI returned non-UTF-8 session transport name: {error}"),
			)
		})?;
		Ok(text.to_owned())
	}

	/// The version, codec, and feature set this live session settled with its
	/// partner. No Host preference is inferred at this layer.
	pub fn profile(&self) -> Result<SessionProfile> {
		self.shared.guard_open()?;
		let mut captp_version = 0;
		let mut codec = 0;
		let mut features = 0;
		check_host(unsafe {
			ffi::pancake_host_session_profile(self.shared.ptr.get(), &mut captp_version, &mut codec, &mut features)
		})?;
		Ok(SessionProfile {
			captp_version: CaptpVersion::from_c(captp_version)?,
			codec: Codec::from_c(codec)?,
			features: FeatureSet::from_bits(features).ok_or_else(|| {
				Error::with_detail(
					sys::ERR_INTERNAL,
					format!("pancake ABI returned unknown session feature mask {features}"),
				)
			})?,
		})
	}
}
