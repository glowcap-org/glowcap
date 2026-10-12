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
		// SAFETY: `self.shared.ptr` is this session's `GlowcapHostSession` handle, owned by the Host and nulled only
		// when the session is released, and `guard_open` above proved it live; `ptr` and `len` are local out-parameters
		// the callee fills.
		check_host(unsafe { ffi::glowcap_host_session_transport_name(self.shared.ptr.get(), &mut ptr, &mut len) })?;
		if len != 0 && ptr.is_null() {
			return Err(Error::with_detail(
				sys::ERR_INTERNAL,
				"glowcap ABI returned a null session transport name with nonzero length".to_string(),
			));
		}
		let bytes = if len == 0 {
			&[][..]
		} else {
			// SAFETY: after the OK return `check_host` verified, `ptr` is non-null (checked above) and names `len` bytes
			// of the transport name the session retains, which the header says stays valid until the session is
			// released; `self.shared` is not released while `&self` is borrowed, and the bytes are copied into an owned
			// `String` before returning.
			unsafe { core::slice::from_raw_parts(ptr, len) }
		};
		let text = core::str::from_utf8(bytes).map_err(|error| {
			Error::with_detail(
				sys::ERR_INTERNAL,
				format!("glowcap ABI returned non-UTF-8 session transport name: {error}"),
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
		// SAFETY: `self.shared.ptr` is this session's live `GlowcapHostSession` handle (`guard_open` above);
		// `captp_version`, `codec`, and `features` are local `u32` out-parameters the callee fills.
		check_host(unsafe {
			ffi::glowcap_host_session_profile(self.shared.ptr.get(), &mut captp_version, &mut codec, &mut features)
		})?;
		Ok(SessionProfile {
			captp_version: CaptpVersion::from_c(captp_version)?,
			codec: Codec::from_c(codec)?,
			features: FeatureSet::from_bits(features).ok_or_else(|| {
				Error::with_detail(
					sys::ERR_INTERNAL,
					format!("glowcap ABI returned unknown session feature mask {features}"),
				)
			})?,
		})
	}
}
