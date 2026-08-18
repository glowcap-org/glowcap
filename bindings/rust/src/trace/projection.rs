//! Pure validation and text projection for borrowed native trace fields.

use crate::abi_constants_gen::{CAPTP_NEXT, CAPTP_V1_0, CODEC_CAPNP, CODEC_SYRUP};

pub(super) fn view(ptr: *const u8, len: usize, field: &str) -> crate::Result<Option<String>> {
	if len == 0 {
		return Ok(None);
	}
	if ptr.is_null() {
		return Err(crate::Error::with_detail(
			crate::sys::ERR_INTERNAL,
			format!("pancake ABI returned a null trace {field} with nonzero length"),
		));
	}
	let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
	let text = std::str::from_utf8(bytes).map_err(|_| {
		crate::Error::with_detail(
			crate::sys::ERR_INTERNAL,
			format!("pancake ABI returned invalid UTF-8 in trace {field}"),
		)
	})?;
	Ok(Some(text.to_owned()))
}

pub(super) fn codec(code: u32) -> crate::Result<&'static str> {
	match code {
		CODEC_CAPNP => Ok("capnp"),
		CODEC_SYRUP => Ok("syrup"),
		other => Err(crate::Error::with_detail(
			crate::sys::ERR_INTERNAL,
			format!("pancake ABI returned unknown trace codec {other}"),
		)),
	}
}

pub(super) fn captp_version(version: u32) -> crate::Result<&'static str> {
	match version {
		CAPTP_NEXT => Ok("pancake-next"),
		CAPTP_V1_0 => Ok("1.0"),
		other => Err(crate::Error::with_detail(
			crate::sys::ERR_INTERNAL,
			format!("pancake ABI returned unknown trace CapTP version {other}"),
		)),
	}
}

/// The message tag as lowercase hex. The bytes ride inline in the ABI record,
/// so projection has no lifetime beyond this call.
pub(super) fn hex(bytes: &[u8]) -> String {
	let mut out = String::with_capacity(bytes.len() * 2);
	for byte in bytes {
		out.push_str(&format!("{byte:02x}"));
	}
	out
}

/// Standard RFC 4648 padded base64 for the bounded trace payload prefix.
pub(super) fn base64(bytes: &[u8]) -> String {
	const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
	for chunk in bytes.chunks(3) {
		let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
		let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
		out.push(ALPHABET[(n >> 18) as usize & 63] as char);
		out.push(ALPHABET[(n >> 12) as usize & 63] as char);
		out.push(if chunk.len() > 1 {
			ALPHABET[(n >> 6) as usize & 63] as char
		} else {
			'='
		});
		out.push(if chunk.len() > 2 {
			ALPHABET[n as usize & 63] as char
		} else {
			'='
		});
	}
	out
}
