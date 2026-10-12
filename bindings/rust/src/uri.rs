//! OCapN locator URIs, the core grammar, for the safe Rust surface.
//!
//! The `ocapn://<designator>.<transport>[?hints]` form is core OCapN vocabulary,
//! defined once in libglowcap_ocapn's `glowcap_uri_*` / `glowcap_locator_*` surface, so
//! the Rust binding hand-rolls no percent codec and reaches the same grammar a
//! TCP-only consumer does. [`parse_locator`] copies every borrowed view into an
//! owned [`Locator`] before releasing the handle. [`format_peer_uri`] and
//! [`encode_peer_locator`] render through the same
//! grammar. All of it is pure grammar over the always-linked core, so the whole
//! module is available in every build, transports and async aside.

use std::collections::BTreeMap;

use core::ffi::{c_int, c_uchar};

use crate::{CaptpVersion, Error, Result, check, sys};

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

impl Locator {
	/// A locator carrying no hints, for a caller that holds only a transport
	/// and a designator. The wire form matches the core's empty-hints default.
	pub fn bare(transport: &str, designator: &str) -> Self {
		Self {
			transport: transport.to_string(),
			designator: designator.to_string(),
			hints: BTreeMap::new(),
			hint_wire_form: HintWireForm::BooleanFalse,
		}
	}
	/// Add routing information while selecting the map wire form required to
	/// carry it. A bare locator's boolean-false form cannot contain entries.
	pub fn with_hint(mut self, name: impl Into<String>, value: HintValue) -> Self {
		self.hints.insert(name.into(), value);
		self.hint_wire_form = HintWireForm::Map;
		self
	}
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

	/// The string hint `name` a transport needs before it can act on this
	/// locator. An absent, empty, or non-string hint is refused as
	/// `ERR_INVALID_ARGUMENT`, so no caller acts on an empty stand-in.
	pub fn require_string_hint(&self, name: &str) -> Result<&str> {
		match self.string_hint(name)? {
			Some(value) if !value.is_empty() => Ok(value),
			_ => Err(Error::with_detail(
				sys::ERR_INVALID_ARGUMENT,
				format!("{} locator requires a non-empty {name:?} string hint", self.transport),
			)),
		}
	}
}

/// Parse an `ocapn://` peer URI into its structured locator fields through the
/// core grammar. Errors (as `ERR_INVALID_ARGUMENT`, with the reason on the
/// error's message) for a malformed URI.
pub fn parse_locator(uri: &str) -> Result<Locator> {
	let bytes = uri.as_bytes();
	let mut raw: *mut sys::GlowcapLocator = core::ptr::null_mut();
	// SAFETY: `raw` is a local out-parameter the callee fills with a new owned `GlowcapLocator`; `bytes` borrows `uri`
	// for the whole call, and the callee parses it during the call without retaining the pointer.
	check(unsafe { sys::glowcap_uri_parse_peer(bytes.as_ptr(), bytes.len(), &mut raw) })?;
	OwnedLocator::adopt(raw)?.value()
}

/// Parse an `ocapn://…/s/<swiss>` sturdyref URI under its CapTP profile,
/// recovering its swissnum.
pub fn parse_sturdyref(uri: &str, captp_version: CaptpVersion) -> Result<SturdyRef> {
	let bytes = uri.as_bytes();
	let mut raw: *mut sys::GlowcapSturdyRef = core::ptr::null_mut();
	// SAFETY: `raw` is a local out-parameter the callee fills with a new owned `GlowcapSturdyRef`; `bytes` borrows
	// `uri` for the whole call, and the callee parses it during the call without retaining the pointer.
	check(unsafe { sys::glowcap_uri_parse_sturdyref(captp_version.to_c(), bytes.as_ptr(), bytes.len(), &mut raw) })?;
	OwnedSturdyRef::adopt(raw)?.value()
}

pub(crate) struct OwnedLocator(*mut sys::GlowcapLocator);

impl OwnedLocator {
	pub(crate) fn new(locator: &Locator) -> Result<Self> {
		let wire_form = match locator.hint_wire_form {
			HintWireForm::Map => sys::HINTS_MAP,
			HintWireForm::BooleanFalse => sys::HINTS_BOOLEAN_FALSE,
		};
		let mut raw = core::ptr::null_mut();
		// SAFETY: `locator.transport` and `locator.designator` are `String`s of the borrowed `locator`, live for the
		// whole call; the callee copies both into the new locator it writes to the local out-parameter `raw`.
		check(unsafe {
			sys::glowcap_locator_new(
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
			// SAFETY: `owned.0` is the live handle `OwnedLocator::adopt` took from `glowcap_locator_new`, released only
			// by `OwnedLocator`'s `Drop`; `name` and each `value` borrow `locator.hints` for the call, and the callee
			// copies them into the locator before returning.
			let rc = unsafe {
				match value {
					HintValue::String(value) => {
						sys::glowcap_locator_add_string(owned.0, name.as_ptr(), name.len(), value.as_ptr(), value.len())
					}
					HintValue::Bytes(value) => {
						sys::glowcap_locator_add_bytes(owned.0, name.as_ptr(), name.len(), value.as_ptr(), value.len())
					}
					HintValue::Boolean(value) => {
						sys::glowcap_locator_add_boolean(owned.0, name.as_ptr(), name.len(), u8::from(*value))
					}
					HintValue::Integer(value) => {
						sys::glowcap_locator_add_integer(owned.0, name.as_ptr(), name.len(), *value)
					}
				}
			};
			check(rc)?;
		}
		Ok(owned)
	}

	pub(crate) fn adopt(raw: *mut sys::GlowcapLocator) -> Result<Self> {
		if raw.is_null() {
			return Err(Error::with_detail(
				sys::ERR_INVALID_ARGUMENT,
				"OCapN returned a null locator handle".to_string(),
			));
		}
		Ok(Self(raw))
	}

	pub(crate) fn clone_view(view: *const sys::GlowcapLocatorView) -> Result<Self> {
		let mut raw = core::ptr::null_mut();
		// SAFETY: `view` is a `GlowcapLocatorView` the caller borrowed from a live locator or sturdyref handle, valid
		// for this call; `raw` is a local out-parameter the callee fills with a new owned locator that copies the view.
		check(unsafe { sys::glowcap_locator_clone(view, &mut raw) })?;
		Self::adopt(raw)
	}

	pub(crate) fn borrow_view(&self) -> Result<*const sys::GlowcapLocatorView> {
		let mut view = core::ptr::null();
		// SAFETY: `self.0` is this `OwnedLocator`'s handle from `glowcap_locator_new` or `adopt`, released only by its
		// `Drop`; `view` is a local out-parameter the callee fills with a pointer borrowed from that handle until it is
		// mutated or released.
		check(unsafe { sys::glowcap_locator_borrow_view(self.0, &mut view) })?;
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
			// SAFETY: the accessor that produced this view keeps it live for the
			// call, and the empty and null arms above have already run.
			Ok(unsafe { core::slice::from_raw_parts(ptr, len) })
		}

		unsafe fn text(ptr: *const u8, len: usize) -> Result<String> {
			// SAFETY: same view, same call window; `bytes` copies before returning.
			String::from_utf8(unsafe { bytes(ptr, len) }?.to_vec()).map_err(|_| {
				Error::with_detail(
					sys::ERR_INVALID_ARGUMENT,
					"OCapN returned non-UTF-8 locator text".to_string(),
				)
			})
		}

		unsafe fn field(
			raw: *mut sys::GlowcapLocator,
			accessor: unsafe extern "C" fn(*mut sys::GlowcapLocator, *mut *const u8, *mut usize) -> c_int,
		) -> Result<String> {
			let mut ptr = core::ptr::null();
			let mut len = 0;
			// SAFETY: `raw` is this `OwnedLocator`'s live handle, and the view
			// the accessor writes out borrows from it until the next mutation,
			// which `text` copies out of before returning.
			check(unsafe { accessor(raw, &mut ptr, &mut len) })?;
			// SAFETY: `text` reads the `ptr` and `len` the accessor just wrote above, which borrow from the same live
			// `raw` handle with no mutation in between, and copies them into an owned `String` before returning.
			unsafe { text(ptr, len) }
		}

		let mut count = 0;
		// SAFETY: `self.0` is this `OwnedLocator`'s live handle, released only by its `Drop`; `count` is a local
		// out-parameter the callee writes.
		check(unsafe { sys::glowcap_locator_hint_count(self.0, &mut count) })?;
		let mut hints = BTreeMap::new();
		for index in 0..count {
			// SAFETY: `GlowcapLocatorHintView` is a plain C struct of integers and null pointers; all-zero is a valid
			// value, and `glowcap_locator_hint_at` fills it before it is read.
			let mut hint: sys::GlowcapLocatorHintView = unsafe { core::mem::zeroed() };
			// SAFETY: `self.0` is this `OwnedLocator`'s live handle, and `index` is below the `count` just read from
			// it; `hint` is a local out-parameter the callee fills with views borrowed from the handle until it is
			// mutated or released.
			check(unsafe { sys::glowcap_locator_hint_at(self.0, index, &mut hint) })?;
			// SAFETY: `hint.name` and `hint.name_len` were filled by `glowcap_locator_hint_at` just above and borrow
			// from `self.0`, which is not mutated before `text` copies them into an owned `String`.
			let name = unsafe { text(hint.name, hint.name_len)? };
			let value = match hint.kind {
				// SAFETY: `hint.bytes` and `hint.bytes_len` were filled by `glowcap_locator_hint_at` just above and
				// borrow from `self.0`, which is not mutated before `text` copies them into an owned `String`.
				sys::HINT_STRING => HintValue::String(unsafe { text(hint.bytes, hint.bytes_len)? }),
				// SAFETY: `hint.bytes` and `hint.bytes_len` were filled by `glowcap_locator_hint_at` just above and
				// borrow from `self.0`, which is not mutated before `bytes` is copied out with `to_vec`.
				sys::HINT_BYTES => HintValue::Bytes(unsafe { bytes(hint.bytes, hint.bytes_len)?.to_vec() }),
				sys::HINT_BOOLEAN if hint.boolean_value <= 1 => HintValue::Boolean(hint.boolean_value != 0),
				sys::HINT_INTEGER => HintValue::Integer(hint.integer_value),
				_ => {
					return Err(Error::with_detail(
						sys::ERR_INVALID_ARGUMENT,
						"OCapN returned an invalid locator hint".to_string(),
					));
				}
			};
			hints.insert(name, value);
		}

		let mut raw_wire_form = 0;
		// SAFETY: `self.0` is this `OwnedLocator`'s live handle, released only by its `Drop`; `raw_wire_form` is a
		// local out-parameter the callee writes.
		check(unsafe { sys::glowcap_locator_hint_wire_form(self.0, &mut raw_wire_form) })?;
		let hint_wire_form = match raw_wire_form {
			sys::HINTS_MAP => HintWireForm::Map,
			sys::HINTS_BOOLEAN_FALSE => HintWireForm::BooleanFalse,
			_ => {
				return Err(Error::with_detail(
					sys::ERR_INVALID_ARGUMENT,
					"OCapN returned an invalid locator hint wire form".to_string(),
				));
			}
		};

		Ok(Locator {
			// SAFETY: `self.0` is this `OwnedLocator`'s live handle, and `sys::glowcap_locator_transport` is the
			// accessor `field` expects; `field` copies the borrowed view into an owned `String` before returning.
			transport: unsafe { field(self.0, sys::glowcap_locator_transport)? },
			// SAFETY: `self.0` is this `OwnedLocator`'s live handle, and `sys::glowcap_locator_designator` is the
			// accessor `field` expects; `field` copies the borrowed view into an owned `String` before returning.
			designator: unsafe { field(self.0, sys::glowcap_locator_designator)? },
			hints,
			hint_wire_form,
		})
	}
}

struct OwnedSturdyRef(*mut sys::GlowcapSturdyRef);

impl OwnedSturdyRef {
	fn adopt(raw: *mut sys::GlowcapSturdyRef) -> Result<Self> {
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
		// SAFETY: `self.0` is this `OwnedSturdyRef`'s handle from `glowcap_uri_parse_sturdyref`, released only by its
		// `Drop`; `view` is a local out-parameter the callee fills with a locator view borrowed from that handle.
		check(unsafe { sys::glowcap_sturdyref_borrow_locator(self.0, &mut view) })?;
		let locator = OwnedLocator::clone_view(view)?.value()?;

		let mut ptr = core::ptr::null();
		let mut len = 0;
		// SAFETY: `self.0` is this `OwnedSturdyRef`'s live handle; `ptr` and `len` are local out-parameters the callee
		// fills with the swissnum range borrowed from the handle.
		check(unsafe { sys::glowcap_sturdyref_swissnum(self.0, &mut ptr, &mut len) })?;
		let swissnum = if len == 0 {
			Vec::new()
		} else if ptr.is_null() {
			return Err(Error::with_detail(
				sys::ERR_INVALID_ARGUMENT,
				"OCapN returned a null sturdyref swissnum".to_string(),
			));
		} else {
			// SAFETY: `ptr` is non-null here and `len` is nonzero, from `glowcap_sturdyref_swissnum` on the live
			// `self.0`, which is not mutated before `to_vec` copies the range.
			unsafe { core::slice::from_raw_parts(ptr, len) }.to_vec()
		};
		Ok(SturdyRef { locator, swissnum })
	}
}

impl Drop for OwnedSturdyRef {
	fn drop(&mut self) {
		// SAFETY: `self.0` is the handle `OwnedSturdyRef::adopt` took from `glowcap_uri_parse_sturdyref`; `Drop` runs
		// once and nothing uses the handle afterwards.
		unsafe { sys::glowcap_sturdyref_release(self.0) };
	}
}

impl Drop for OwnedLocator {
	fn drop(&mut self) {
		// SAFETY: `self.0` is the handle `OwnedLocator::adopt` took, non-null by that check; `Drop` runs once and
		// nothing uses the handle afterwards.
		unsafe { sys::glowcap_locator_release(self.0) };
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
	// SAFETY: the caller declares the view live, and the guard above has taken
	// the empty and null cases `from_raw_parts` refuses.
	String::from_utf8_lossy(unsafe { core::slice::from_raw_parts(ptr, len) }).into_owned()
}

mod format;
#[cfg(all(feature = "async", any(feature = "tcp", all(test, feature = "iroh"))))]
pub(crate) use format::format_peer_locator;
pub use format::{designator_host_port, encode_peer_locator, format_locator_uri, format_peer_uri, format_sturdyref};

#[cfg(test)]
mod tests {
	use std::collections::BTreeMap;

	#[cfg(feature = "tcp")]
	use super::format_sturdyref;
	use super::{HintValue, HintWireForm, Locator, parse_sturdyref};
	use crate::CaptpVersion;

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
	fn require_string_hint_refuses_an_absent_empty_or_mismatched_hint() {
		let mut hints = BTreeMap::new();
		hints.insert("priority".to_string(), HintValue::Integer(1));
		hints.insert("route".to_string(), HintValue::String(String::new()));
		hints.insert(
			"relay".to_string(),
			HintValue::String("wss://relay.example/relay".to_string()),
		);
		let locator = Locator {
			transport: "test".to_string(),
			designator: "peer".to_string(),
			hints,
			hint_wire_form: HintWireForm::Map,
		};

		assert_eq!(
			locator.require_string_hint("relay").expect("present hint"),
			"wss://relay.example/relay"
		);
		for name in ["missing", "route", "priority"] {
			let error = locator.require_string_hint(name).expect_err("refused hint");
			assert_eq!(error.code(), crate::sys::ERR_INVALID_ARGUMENT);
		}
	}

	#[test]
	fn sturdyref_parse_preserves_locator_and_swiss_authority() {
		let sturdyref = parse_sturdyref(
			"ocapn://wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd.onion/s/eQjP4nR28ffX5eoNCK5DWH6DT_d7BIqD3-My459CUbU",
			CaptpVersion::V1_0,
		)
		.expect("canonical sturdyref parses");

		assert_eq!(sturdyref.locator.transport, "onion");
		assert_eq!(
			sturdyref.swissnum,
			[
				0x79, 0x08, 0xcf, 0xe2, 0x74, 0x76, 0xf1, 0xf7, 0xd7, 0xe5, 0xea, 0x0d, 0x08, 0xae, 0x43, 0x58, 0x7e,
				0x83, 0x4f, 0xf7, 0x7b, 0x04, 0x8a, 0x83, 0xdf, 0xe3, 0x32, 0xe3, 0x9f, 0x42, 0x51, 0xb5,
			]
		);
	}

	#[cfg(feature = "tcp")]
	#[test]
	fn sturdyref_format_round_trips_opaque_authority() {
		let locator = crate::tcp::locator("127.0.0.1", 9045);
		let swiss = b"durable:0123456789abcdef";
		let uri = format_sturdyref(&locator, swiss, CaptpVersion::Next).expect("sturdyref formats");
		assert!(uri.ends_with("/s/durable%3A0123456789abcdef"));
		let parsed = parse_sturdyref(&uri, CaptpVersion::Next).expect("formatted sturdyref parses");
		assert_eq!(parsed.swissnum, swiss);
		assert_eq!(parsed.locator.transport, "tcp");
	}
}
