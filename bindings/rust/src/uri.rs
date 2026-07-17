//! OCapN locator URIs, the core grammar, for the safe Rust surface.
//!
//! The `ocapn://<designator>.<transport>[?hints]` form is core OCapN vocabulary,
//! defined once in libpancake_ocapn's `pancake_uri_*` / `pancake_locator_*` surface, so
//! the Rust binding hand-rolls no percent codec and reaches the same grammar a
//! TCP-only consumer does. [`parse_locator`] copies every borrowed view into an
//! owned [`Locator`] before releasing the handle; [`format_peer_uri`],
//! [`tcp_locator`], and [`encode_peer_locator`] render through the same
//! grammar. All of it is pure grammar over the always-linked core, so the whole
//! module is available in every build, transports and async aside.

use std::collections::BTreeMap;

use core::ffi::{c_int, c_uchar};

use crate::{check, sys, Error, Result};

/// A parsed OCapN locator: the structured fields a parse yields. `swissnum` is
/// empty for a peer URI, the swiss bytes for a sturdyref.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Locator {
	/// The transport the locator addresses (e.g. `tcp`, `iroh`).
	pub transport: String,
	/// The transport-specific address (a TCP `host:port`, an iroh node id).
	pub designator: String,
	/// Empty for a peer URI; the swiss bytes for a sturdyref.
	pub swissnum: String,
	/// The locator's hints, keyed by name (e.g. `direct-addresses`).
	pub hints: BTreeMap<String, String>,
}

/// Parse an `ocapn://` peer URI into its structured locator fields through the
/// core grammar. Errors (as `ERR_INVALID_ARGUMENT`, with the reason on the
/// error's message) for a malformed URI.
pub fn parse_locator(uri: &str) -> Result<Locator> {
	parse_with(uri, false)
}

/// Parse an `ocapn://…/s/<swiss>` sturdyref URI, recovering its swissnum.
pub fn parse_sturdyref(uri: &str) -> Result<Locator> {
	parse_with(uri, true)
}

fn parse_with(uri: &str, sturdyref: bool) -> Result<Locator> {
	let bytes = uri.as_bytes();
	let mut loc: *mut sys::PancakeLocator = core::ptr::null_mut();
	let rc = unsafe {
		if sturdyref {
			sys::pancake_uri_parse_sturdyref(bytes.as_ptr(), bytes.len(), &mut loc)
		} else {
			sys::pancake_uri_parse_peer(bytes.as_ptr(), bytes.len(), &mut loc)
		}
	};
	check(rc)?;
	// Always release the handle, even if an accessor fails midway through.
	let result = unsafe { read_locator(loc) };
	unsafe { sys::pancake_locator_release(loc) };
	result
}

unsafe fn read_locator(loc: *mut sys::PancakeLocator) -> Result<Locator> {
	let transport = read_field(sys::pancake_locator_transport, loc)?;
	let designator = read_field(sys::pancake_locator_designator, loc)?;
	let swissnum = read_field(sys::pancake_locator_swissnum, loc)?;

	let mut count: usize = 0;
	check(sys::pancake_locator_hint_count(loc, &mut count))?;
	let mut hints = BTreeMap::new();
	for i in 0..count {
		let (mut kp, mut vp): (*const c_uchar, *const c_uchar) =
			(core::ptr::null(), core::ptr::null());
		let (mut kl, mut vl): (usize, usize) = (0, 0);
		check(sys::pancake_locator_hint_at(
			loc, i, &mut kp, &mut kl, &mut vp, &mut vl,
		))?;
		hints.insert(view_to_string(kp, kl), view_to_string(vp, vl));
	}

	Ok(Locator {
		transport,
		designator,
		swissnum,
		hints,
	})
}

unsafe fn read_field(
	accessor: unsafe extern "C" fn(
		*mut sys::PancakeLocator,
		*mut *const c_uchar,
		*mut usize,
	) -> c_int,
	loc: *mut sys::PancakeLocator,
) -> Result<String> {
	let mut ptr: *const c_uchar = core::ptr::null();
	let mut len: usize = 0;
	check(accessor(loc, &mut ptr, &mut len))?;
	Ok(view_to_string(ptr, len))
}

unsafe fn view_to_string(ptr: *const c_uchar, len: usize) -> String {
	if len == 0 || ptr.is_null() {
		return String::new();
	}
	String::from_utf8_lossy(core::slice::from_raw_parts(ptr, len)).into_owned()
}

/// Format a peer locator as an `ocapn://<designator>.<transport>[?hints]` URI
/// through the core grammar.
pub fn format_peer_uri(
	transport: &str,
	designator: &str,
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
	// Size with a generous buffer; the call reports the exact length, so a
	// too-small buffer is retried at the reported size.
	let mut cap = 256usize;
	loop {
		let mut buf = vec![0u8; cap];
		let mut out_len: usize = 0;
		let rc = unsafe {
			sys::pancake_uri_format_peer(
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

/// Render host:port as a tcp designator; bracket IPv6 for the core grammar.
pub fn socket_addr_designator(host: &str, port: u16) -> String {
	if host.contains(':') && !(host.starts_with('[') && host.ends_with(']')) {
		format!("[{host}]:{port}")
	} else {
		format!("{host}:{port}")
	}
}

/// Split a bare designator as `host:port` through the core grammar
/// (`pancake_designator_host_port`). Prefer this over minting a peer URI
/// just to call [`parse_locator`].
pub fn designator_host_port(designator: &str) -> Result<(String, u16)> {
	let mut host_ptr: *const c_uchar = core::ptr::null();
	let mut host_len: usize = 0;
	let mut port: u16 = 0;
	check(unsafe {
		sys::pancake_designator_host_port(
			designator.as_ptr(),
			designator.len(),
			&mut host_ptr,
			&mut host_len,
			&mut port,
		)
	})?;
	Ok((unsafe { view_to_string(host_ptr, host_len) }, port))
}

/// Build a `tcp` locator from a literal host and port: `ocapn://host:port.tcp`,
/// rendered through the core grammar. The convenience for the common case — a
/// caller holding a host and port passes `connect(&tcp_locator(host, port))`
/// instead of hand-formatting the URI. `host:port` is not a dial of its own; it
/// is a locator like any other.
pub fn tcp_locator(host: &str, port: u16) -> String {
	format_peer_uri(
		crate::abi_constants::TRANSPORT_TCP,
		&socket_addr_designator(host, port),
		&BTreeMap::new(),
	)
	.expect("a tcp host:port locator always formats through the core grammar")
}

/// Build a `keyed-tcp` locator: the designator is the listener's Ed25519 public
/// key in canonical hex, and `host`/`port` ride the `direct-addresses` hint
/// (ADR-0075). A partner dials with [`crate::connect`] and re-dials after a
/// restart with only the hint updated.
pub fn keyed_tcp_locator(designator: &str, host: &str, port: u16) -> String {
	let mut hints = BTreeMap::new();
	hints.insert(
		crate::abi_constants::HINT_DIRECT_ADDRESSES.to_string(),
		socket_addr_designator(host, port),
	);
	format_peer_uri(
		crate::abi_constants::TRANSPORT_KEYED_TCP,
		designator,
		&hints,
	)
	.expect("a keyed-tcp locator always formats through the core grammar")
}

/// Build the verbatim exporter location-record bytes a gifter embeds in a give
/// when the exporter is reachable only by a dial hint (ADR-0009) — the
/// construct-it-yourself counterpart of the partner's signed session record, for
/// an exporter whose own record carries no hint. `transport`/`designator` name
/// the exporter; a non-empty `direct_addresses` (comma-separated socket
/// addresses) adds a `direct-addresses` hint so a cross-process recipient dials
/// it directly with no discovery service (an iroh exporter reachable only by
/// address). The result feeds `Session::set_exporter_locator`. An empty
/// `direct_addresses` yields a hint-less location identical to the exporter's own
/// signed record, so a TCP or discovery-reachable exporter needs no override.
pub fn encode_peer_locator(
	transport: &str,
	designator: &str,
	direct_addresses: &str,
) -> Result<Vec<u8>> {
	let mut out: *mut u8 = core::ptr::null_mut();
	let mut out_len: usize = 0;
	check(unsafe {
		sys::pancake_encode_peer_locator(
			transport.as_ptr(),
			transport.len(),
			designator.as_ptr(),
			designator.len(),
			direct_addresses.as_ptr(),
			direct_addresses.len(),
			&mut out,
			&mut out_len,
		)
	})?;
	let bytes = if out.is_null() || out_len == 0 {
		Vec::new()
	} else {
		unsafe { core::slice::from_raw_parts(out, out_len) }.to_vec()
	};
	unsafe { sys::pancake_peer_locator_bytes_release(out, out_len) };
	Ok(bytes)
}
