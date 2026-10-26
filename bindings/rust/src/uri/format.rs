//! Rendering of typed locators and sturdyrefs through the core grammar.
use std::collections::BTreeMap;

use core::ffi::c_uchar;

use super::{Locator, OwnedLocator, view_to_string};
use crate::{CaptpVersion, Error, Result, check, sys};

/// Format a peer locator as an `ocapn://<designator>.<transport>[?hints]` URI
/// through the core grammar.
pub fn format_peer_uri(transport: &str, designator: &str, hints: &BTreeMap<String, String>) -> Result<String> {
	format_uri(transport, designator, None, hints)
}

/// Add opaque swiss authority to a typed peer locator and render a sturdyref
/// under the selected CapTP profile.
pub fn format_sturdyref(locator: &Locator, swissnum: &[u8], captp_version: CaptpVersion) -> Result<String> {
	let mut hints = BTreeMap::new();
	for (name, value) in &locator.hints {
		let value = value
			.as_str()
			.ok_or_else(|| Error::from_code(sys::ERR_INVALID_ARGUMENT))?;
		hints.insert(name.clone(), value.to_string());
	}
	format_uri(
		&locator.transport,
		&locator.designator,
		Some((swissnum, captp_version)),
		&hints,
	)
}

fn format_uri(
	transport: &str,
	designator: &str,
	swissnum: Option<(&[u8], CaptpVersion)>,
	hints: &BTreeMap<String, String>,
) -> Result<String> {
	let keys: Vec<&[u8]> = hints.keys().map(|k| k.as_bytes()).collect();
	let vals: Vec<&[u8]> = hints.values().map(|v| v.as_bytes()).collect();
	let key_ptrs: Vec<*const c_uchar> = keys.iter().map(|k| k.as_ptr()).collect();
	let val_ptrs: Vec<*const c_uchar> = vals.iter().map(|v| v.as_ptr()).collect();
	let key_lens: Vec<usize> = keys.iter().map(|k| k.len()).collect();
	let val_lens: Vec<usize> = vals.iter().map(|v| v.len()).collect();
	let n = hints.len();

	let (kp, klp, vp, vlp) = if n == 0 {
		(
			core::ptr::null(),
			core::ptr::null(),
			core::ptr::null(),
			core::ptr::null(),
		)
	} else {
		(
			key_ptrs.as_ptr(),
			key_lens.as_ptr(),
			val_ptrs.as_ptr(),
			val_lens.as_ptr(),
		)
	};

	let t = transport.as_bytes();
	let d = designator.as_bytes();
	let mut cap: usize = 0;
	// SAFETY: `t`, `d` and `swiss` borrow the caller's `transport`, `designator` and `swissnum` for the call; `kp`,
	// `klp`, `vp` and `vlp` are null when `n` is zero, otherwise they point into the local `key_ptrs`, `key_lens`,
	// `val_ptrs` and `val_lens` vectors of `n` entries whose elements borrow `hints`, all live to the end of the
	// function; the null output with capacity zero asks for the size only, the callee reads every input only during the
	// call, and `cap` is a local out-parameter.
	let rc = unsafe {
		if let Some((swiss, captp_version)) = swissnum {
			sys::glowcap_uri_format_sturdyref(
				captp_version.to_c(),
				t.as_ptr(),
				t.len(),
				d.as_ptr(),
				d.len(),
				swiss.as_ptr(),
				swiss.len(),
				kp,
				klp,
				vp,
				vlp,
				n,
				core::ptr::null_mut(),
				0,
				&mut cap,
			)
		} else {
			sys::glowcap_uri_format_peer(
				t.as_ptr(),
				t.len(),
				d.as_ptr(),
				d.len(),
				kp,
				klp,
				vp,
				vlp,
				n,
				core::ptr::null_mut(),
				0,
				&mut cap,
			)
		}
	};
	if rc != sys::ERR_BUFFER_TOO_SMALL {
		check(rc)?;
		if cap == 0 {
			return Ok(String::new());
		}
	}
	loop {
		let mut buf = vec![0u8; cap];
		let mut out_len: usize = 0;
		// SAFETY: as the sizing call above for `t`, `d`, `swiss`, and the hint arrays `kp`, `klp`, `vp` and `vlp`;
		// `buf` is a live local `Vec<u8>` of `cap` bytes the callee writes during the call, and `out_len` is a local
		// out-parameter.
		let rc = unsafe {
			if let Some((swiss, captp_version)) = swissnum {
				sys::glowcap_uri_format_sturdyref(
					captp_version.to_c(),
					t.as_ptr(),
					t.len(),
					d.as_ptr(),
					d.len(),
					swiss.as_ptr(),
					swiss.len(),
					kp,
					klp,
					vp,
					vlp,
					n,
					buf.as_mut_ptr(),
					cap,
					&mut out_len,
				)
			} else {
				sys::glowcap_uri_format_peer(
					t.as_ptr(),
					t.len(),
					d.as_ptr(),
					d.len(),
					kp,
					klp,
					vp,
					vlp,
					n,
					buf.as_mut_ptr(),
					cap,
					&mut out_len,
				)
			}
		};
		if rc == sys::OK {
			buf.truncate(out_len);
			return Ok(String::from_utf8_lossy(&buf).into_owned());
		}
		if rc == sys::ERR_BUFFER_TOO_SMALL && out_len > cap {
			cap = out_len;
			continue;
		}
		return Err(Error::from_code(rc));
	}
}

#[cfg(all(feature = "async", any(feature = "tcp", all(test, feature = "iroh"))))]
pub(crate) fn format_peer_locator(transport: &str, designator: &str, direct_addresses: &str) -> Result<String> {
	let mut hints = BTreeMap::new();
	if !direct_addresses.is_empty() {
		hints.insert(
			crate::abi_constants::HINT_DIRECT_ADDRESSES.to_string(),
			direct_addresses.to_string(),
		);
	}
	format_peer_uri(transport, designator, &hints)
}

/// Render a typed peer locator as its canonical `ocapn://` URI.
///
/// Keep locators typed while dialing and serving. Serialize only at text
/// boundaries such as configuration, logs, and sturdyref construction.
pub fn format_locator_uri(locator: &Locator) -> Result<String> {
	let mut hints = BTreeMap::new();
	for (name, value) in &locator.hints {
		let value = value.as_str().ok_or_else(|| {
			Error::with_detail(
				sys::ERR_INVALID_ARGUMENT,
				format!("locator hint {name:?} has no lossless URI spelling"),
			)
		})?;
		hints.insert(name.clone(), value.to_owned());
	}
	format_peer_uri(&locator.transport, &locator.designator, &hints)
}

/// Split a bare designator as `host:port` through the core grammar
/// (`glowcap_designator_host_port`). Prefer this over minting a peer URI
/// just to call [`crate::parse_locator`].
pub fn designator_host_port(designator: &str) -> Result<(String, u16)> {
	let mut host_ptr: *const c_uchar = core::ptr::null();
	let mut host_len: usize = 0;
	let mut port: u16 = 0;
	// SAFETY: `designator` is a borrowed `&str` live for the call, and the callee reads it only during the call;
	// `host_ptr` and `host_len` are local out-parameters the callee fills with a view into that `designator`, and
	// `port` is a local out-parameter.
	check(unsafe {
		sys::glowcap_designator_host_port(
			designator.as_ptr(),
			designator.len(),
			&mut host_ptr,
			&mut host_len,
			&mut port,
		)
	})?;
	// SAFETY: `host_ptr` and `host_len` were just filled by `glowcap_designator_host_port` with a view into
	// `designator`, borrowed and unmodified, and `view_to_string` copies it into an owned `String` before returning.
	Ok((unsafe { view_to_string(host_ptr, host_len) }, port))
}

/// Encode a complete typed locator as the canonical signed handoff record.
pub fn encode_peer_locator(locator: &Locator) -> Result<Vec<u8>> {
	let owned = OwnedLocator::new(locator)?;
	let mut out: *mut u8 = core::ptr::null_mut();
	let mut out_len: usize = 0;
	// SAFETY: `owned` is the live `OwnedLocator` made above, whose `borrow_view` result is valid until `owned` is
	// mutated or dropped, and neither happens during the call; `out` and `out_len` are local out-parameters the callee
	// fills with an owned byte buffer that this function releases below.
	check(unsafe { sys::glowcap_locator_record_encode(owned.borrow_view()?, &mut out, &mut out_len) })?;
	let bytes = if out.is_null() || out_len == 0 {
		Vec::new()
	} else {
		// SAFETY: `out` is non-null and `out_len` is nonzero here, the buffer `glowcap_locator_record_encode` just
		// filled, which stays allocated until the release below; `to_vec` copies it first.
		unsafe { core::slice::from_raw_parts(out, out_len) }.to_vec()
	};
	// SAFETY: `out` and `out_len` are exactly what `glowcap_locator_record_encode` returned, released here once after
	// the copy, and the release is a no-op for a null `out`; nothing reads the buffer afterwards.
	unsafe { sys::glowcap_locator_record_bytes_release(out, out_len) };
	Ok(bytes)
}
