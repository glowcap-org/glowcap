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

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HintValue {
	String(String),
	Bytes(Vec<u8>),
	Boolean(bool),
	Integer(i64),
}

impl HintValue {
	fn as_str(&self) -> Option<&str> {
		match self {
			Self::String(value) => Some(value),
			_ => None,
		}
	}
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HintWireForm {
	Map,
	BooleanFalse,
}

/// A parsed OCapN peer locator.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Locator {
	/// The transport the locator addresses (e.g. `tcp`, `iroh`).
	pub transport: String,
	/// The transport-specific address (a TCP `host:port`, an iroh node id).
	pub designator: String,
	/// The locator's hints, keyed by name (e.g. `direct-addresses`).
	pub hints: BTreeMap<String, HintValue>,
	pub hint_wire_form: HintWireForm,
}

/// A parsed OCapN sturdyref. The swissnum is authority, so it never collapses
/// into a peer [`Locator`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SturdyRef {
	pub locator: Locator,
	pub swissnum: Vec<u8>,
}

impl Locator {
	pub fn string_hint(&self, name: &str) -> Result<Option<&str>> {
		match self.hints.get(name) {
			None => Ok(None),
			Some(HintValue::String(value)) => Ok(Some(value)),
			Some(_) => Err(Error::with_detail(
				sys::ERR_INVALID_ARGUMENT,
				format!("locator hint {name:?} must be a string"),
			)),
		}
	}
}

/// Parse an `ocapn://` peer URI into its structured locator fields through the
/// core grammar. Errors (as `ERR_INVALID_ARGUMENT`, with the reason on the
/// error's message) for a malformed URI.
pub fn parse_locator(uri: &str) -> Result<Locator> {
	let bytes = uri.as_bytes();
	let mut raw: *mut sys::PancakeLocator = core::ptr::null_mut();
	check(unsafe { sys::pancake_uri_parse_peer(bytes.as_ptr(), bytes.len(), &mut raw) })?;
	OwnedLocator::adopt(raw)?.value()
}

/// Parse an `ocapn://…/s/<swiss>` sturdyref URI, recovering its swissnum.
pub fn parse_sturdyref(uri: &str) -> Result<SturdyRef> {
	let bytes = uri.as_bytes();
	let mut raw: *mut sys::PancakeSturdyRef = core::ptr::null_mut();
	check(unsafe { sys::pancake_uri_parse_sturdyref(bytes.as_ptr(), bytes.len(), &mut raw) })?;
	OwnedSturdyRef::adopt(raw)?.value()
}

pub(crate) struct OwnedLocator(*mut sys::PancakeLocator);

impl OwnedLocator {
	pub(crate) fn new(locator: &Locator) -> Result<Self> {
		let wire_form = match locator.hint_wire_form {
			HintWireForm::Map => sys::HINTS_MAP,
			HintWireForm::BooleanFalse => sys::HINTS_BOOLEAN_FALSE,
		};
		let mut raw = core::ptr::null_mut();
		check(unsafe {
			sys::pancake_locator_new(
				locator.transport.as_ptr(),
				locator.transport.len(),
				locator.designator.as_ptr(),
				locator.designator.len(),
				wire_form,
				&mut raw,
			)
		})?;
		let owned = Self::adopt(raw)?;
		for (name, value) in &locator.hints {
			let rc = unsafe {
				match value {
					HintValue::String(value) => sys::pancake_locator_add_string(
						owned.0,
						name.as_ptr(),
						name.len(),
						value.as_ptr(),
						value.len(),
					),
					HintValue::Bytes(value) => sys::pancake_locator_add_bytes(
						owned.0,
						name.as_ptr(),
						name.len(),
						value.as_ptr(),
						value.len(),
					),
					HintValue::Boolean(value) => sys::pancake_locator_add_boolean(
						owned.0,
						name.as_ptr(),
						name.len(),
						u8::from(*value),
					),
					HintValue::Integer(value) => {
						sys::pancake_locator_add_integer(owned.0, name.as_ptr(), name.len(), *value)
					}
				}
			};
			check(rc)?;
		}
		Ok(owned)
	}

	pub(crate) fn adopt(raw: *mut sys::PancakeLocator) -> Result<Self> {
		if raw.is_null() {
			return Err(Error::with_detail(
				sys::ERR_INVALID_ARGUMENT,
				"OCapN returned a null locator handle".to_string(),
			));
		}
		Ok(Self(raw))
	}

	pub(crate) fn clone_view(view: *const sys::PancakeLocatorView) -> Result<Self> {
		let mut raw = core::ptr::null_mut();
		check(unsafe { sys::pancake_locator_clone(view, &mut raw) })?;
		Self::adopt(raw)
	}

	pub(crate) fn borrow_view(&self) -> Result<*const sys::PancakeLocatorView> {
		let mut view = core::ptr::null();
		check(unsafe { sys::pancake_locator_borrow_view(self.0, &mut view) })?;
		Ok(view)
	}

	pub(crate) fn value(&self) -> Result<Locator> {
		unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> Result<&'a [u8]> {
			if len == 0 {
				return Ok(&[]);
			}
			if ptr.is_null() {
				return Err(Error::with_detail(
					sys::ERR_INVALID_ARGUMENT,
					"OCapN returned a null locator view".to_string(),
				));
			}
			Ok(core::slice::from_raw_parts(ptr, len))
		}

		unsafe fn text(ptr: *const u8, len: usize) -> Result<String> {
			String::from_utf8(bytes(ptr, len)?.to_vec()).map_err(|_| {
				Error::with_detail(
					sys::ERR_INVALID_ARGUMENT,
					"OCapN returned non-UTF-8 locator text".to_string(),
				)
			})
		}

		unsafe fn field(
			raw: *mut sys::PancakeLocator,
			accessor: unsafe extern "C" fn(
				*mut sys::PancakeLocator,
				*mut *const u8,
				*mut usize,
			) -> c_int,
		) -> Result<String> {
			let mut ptr = core::ptr::null();
			let mut len = 0;
			check(accessor(raw, &mut ptr, &mut len))?;
			text(ptr, len)
		}

		let mut count = 0;
		check(unsafe { sys::pancake_locator_hint_count(self.0, &mut count) })?;
		let mut hints = BTreeMap::new();
		for index in 0..count {
			let mut hint: sys::PancakeLocatorHintView = unsafe { core::mem::zeroed() };
			check(unsafe { sys::pancake_locator_hint_at(self.0, index, &mut hint) })?;
			let name = unsafe { text(hint.name, hint.name_len)? };
			let value = match hint.kind {
				sys::HINT_STRING => HintValue::String(unsafe { text(hint.bytes, hint.bytes_len)? }),
				sys::HINT_BYTES => {
					HintValue::Bytes(unsafe { bytes(hint.bytes, hint.bytes_len)?.to_vec() })
				}
				sys::HINT_BOOLEAN if hint.boolean_value <= 1 => {
					HintValue::Boolean(hint.boolean_value != 0)
				}
				sys::HINT_INTEGER => HintValue::Integer(hint.integer_value),
				_ => {
					return Err(Error::with_detail(
						sys::ERR_INVALID_ARGUMENT,
						"OCapN returned an invalid locator hint".to_string(),
					))
				}
			};
			hints.insert(name, value);
		}

		let mut raw_wire_form = 0;
		check(unsafe { sys::pancake_locator_hint_wire_form(self.0, &mut raw_wire_form) })?;
		let hint_wire_form = match raw_wire_form {
			sys::HINTS_MAP => HintWireForm::Map,
			sys::HINTS_BOOLEAN_FALSE => HintWireForm::BooleanFalse,
			_ => {
				return Err(Error::with_detail(
					sys::ERR_INVALID_ARGUMENT,
					"OCapN returned an invalid locator hint wire form".to_string(),
				))
			}
		};

		Ok(Locator {
			transport: unsafe { field(self.0, sys::pancake_locator_transport)? },
			designator: unsafe { field(self.0, sys::pancake_locator_designator)? },
			hints,
			hint_wire_form,
		})
	}
}

struct OwnedSturdyRef(*mut sys::PancakeSturdyRef);

impl OwnedSturdyRef {
	fn adopt(raw: *mut sys::PancakeSturdyRef) -> Result<Self> {
		if raw.is_null() {
			return Err(Error::with_detail(
				sys::ERR_INVALID_ARGUMENT,
				"OCapN returned a null sturdyref handle".to_string(),
			));
		}
		Ok(Self(raw))
	}

	fn value(&self) -> Result<SturdyRef> {
		let mut view = core::ptr::null();
		check(unsafe { sys::pancake_sturdyref_borrow_locator(self.0, &mut view) })?;
		let locator = OwnedLocator::clone_view(view)?.value()?;

		let mut ptr = core::ptr::null();
		let mut len = 0;
		check(unsafe { sys::pancake_sturdyref_swissnum(self.0, &mut ptr, &mut len) })?;
		let swissnum = if len == 0 {
			Vec::new()
		} else if ptr.is_null() {
			return Err(Error::with_detail(
				sys::ERR_INVALID_ARGUMENT,
				"OCapN returned a null sturdyref swissnum".to_string(),
			));
		} else {
			unsafe { core::slice::from_raw_parts(ptr, len) }.to_vec()
		};
		Ok(SturdyRef { locator, swissnum })
	}
}

impl Drop for OwnedSturdyRef {
	fn drop(&mut self) {
		unsafe { sys::pancake_sturdyref_release(self.0) };
	}
}

impl Drop for OwnedLocator {
	fn drop(&mut self) {
		unsafe { sys::pancake_locator_release(self.0) };
	}
}

/// # Safety
///
/// Unless `len == 0` or `ptr` is null (both yield an empty string), `ptr` must
/// point to `len` initialized bytes that stay valid for the duration of this
/// call.
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
	format_uri(transport, designator, None, hints)
}

/// Format a peer URI plus opaque swiss authority as a sturdyref through the
/// core grammar. The locator is parsed first so no binding splices URI syntax.
pub fn format_sturdyref(locator_uri: &str, swissnum: &[u8]) -> Result<String> {
	let locator = parse_locator(locator_uri)?;
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
		Some(swissnum),
		&hints,
	)
}

fn format_uri(
	transport: &str,
	designator: &str,
	swissnum: Option<&[u8]>,
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
			if let Some(swiss) = swissnum {
				sys::pancake_uri_format_sturdyref(
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

#[cfg(feature = "async")]
pub(crate) fn format_peer_locator(
	transport: &str,
	designator: &str,
	direct_addresses: &str,
) -> Result<String> {
	let mut hints = BTreeMap::new();
	if !direct_addresses.is_empty() {
		hints.insert(
			crate::abi_constants::HINT_DIRECT_ADDRESSES.to_string(),
			direct_addresses.to_string(),
		);
	}
	format_peer_uri(transport, designator, &hints)
}

#[cfg(feature = "iroh")]
pub(crate) fn format_locator_uri(locator: &Locator) -> Result<String> {
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

/// Build a `noise-tcp` locator: the designator is the listener's durable
/// Ed25519 public key, and `host`/`port` are its direct-addresses hint. The
/// peers authenticate that key and seal the byte channel before CapTP opens.
pub fn noise_tcp_locator(designator: &str, host: &str, port: u16) -> String {
	let mut hints = BTreeMap::new();
	hints.insert(
		crate::abi_constants::HINT_DIRECT_ADDRESSES.to_string(),
		socket_addr_designator(host, port),
	);
	format_peer_uri(
		crate::abi_constants::TRANSPORT_NOISE_TCP,
		designator,
		&hints,
	)
	.expect("a noise-tcp locator always formats through the core grammar")
}

/// Encode a complete typed locator as the canonical signed handoff record.
pub fn encode_peer_locator(locator: &Locator) -> Result<Vec<u8>> {
	let owned = OwnedLocator::new(locator)?;
	let mut out: *mut u8 = core::ptr::null_mut();
	let mut out_len: usize = 0;
	check(unsafe {
		sys::pancake_locator_record_encode(owned.borrow_view()?, &mut out, &mut out_len)
	})?;
	let bytes = if out.is_null() || out_len == 0 {
		Vec::new()
	} else {
		unsafe { core::slice::from_raw_parts(out, out_len) }.to_vec()
	};
	unsafe { sys::pancake_locator_record_bytes_release(out, out_len) };
	Ok(bytes)
}

#[cfg(test)]
mod tests {
	use std::collections::BTreeMap;

	use super::{format_sturdyref, parse_sturdyref, HintValue, HintWireForm, Locator};

	#[test]
	fn string_hint_distinguishes_absence_from_a_type_mismatch() {
		let mut hints = BTreeMap::new();
		hints.insert("priority".to_string(), HintValue::Integer(1));
		let locator = Locator {
			transport: "test".to_string(),
			designator: "peer".to_string(),
			hints,
			hint_wire_form: HintWireForm::Map,
		};

		assert_eq!(locator.string_hint("missing").expect("absent hint"), None);
		assert!(locator.string_hint("priority").is_err());
	}

	#[test]
	fn sturdyref_parse_preserves_locator_and_swiss_authority() {
		let sturdyref = parse_sturdyref(
			"ocapn://wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd.onion/s/eQjP4nR28ffX5eoNCK5DWH6DT_d7BIqD3-My459CUbU",
		)
		.expect("canonical sturdyref parses");

		assert_eq!(sturdyref.locator.transport, "onion");
		assert_eq!(
			sturdyref.swissnum,
			[
				0x79, 0x08, 0xcf, 0xe2, 0x74, 0x76, 0xf1, 0xf7, 0xd7, 0xe5, 0xea, 0x0d, 0x08, 0xae,
				0x43, 0x58, 0x7e, 0x83, 0x4f, 0xf7, 0x7b, 0x04, 0x8a, 0x83, 0xdf, 0xe3, 0x32, 0xe3,
				0x9f, 0x42, 0x51, 0xb5,
			]
		);
	}

	#[test]
	fn sturdyref_format_round_trips_opaque_authority() {
		let locator = "ocapn://127.0.0.1%3A9045.tcp";
		let swiss = b"durable:0123456789abcdef";
		let uri = format_sturdyref(locator, swiss).expect("sturdyref formats");
		let parsed = parse_sturdyref(&uri).expect("formatted sturdyref parses");
		assert_eq!(parsed.swissnum, swiss);
		assert_eq!(parsed.locator.transport, "tcp");
	}
}
