//! Lossless text in existing JavaScript-authored JSON documents. Ordinary text
//! keeps Rust's UTF-8 representation; isolated UTF-16 surrogates use code units.
//! Serialization of the latter uses serde_json's raw-value contract. Browser
//! adapters should exchange its UTF-16 units rather than deserialize it as str.
use alloc::{string::String, vec::Vec};
use core::fmt::{self, Write};
use serde::{
	Deserialize, Deserializer, Serialize, Serializer,
	de::{Error, Visitor},
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DocumentText(Repr);

#[derive(Clone, Debug, PartialEq, Eq)]
enum Repr {
	Utf8(String),
	Utf16(Vec<u16>),
}

impl From<String> for DocumentText {
	fn from(value: String) -> Self {
		Self(Repr::Utf8(value))
	}
}

impl From<&str> for DocumentText {
	fn from(value: &str) -> Self {
		String::from(value).into()
	}
}

impl DocumentText {
	/// Retain only the admitted text, releasing caller-owned spare capacity.
	pub fn compact(self) -> Self {
		Self(match self.0 {
			Repr::Utf8(text) => Repr::Utf8(text.into_boxed_str().into_string()),
			Repr::Utf16(units) => Repr::Utf16(units.into_boxed_slice().into_vec()),
		})
	}
	/// Heap storage owned by this value, including spare capacity. Queue budgets
	/// count retention rather than assuming UTF-16 units equal allocation bytes.
	pub fn heap_bytes(&self) -> usize {
		match &self.0 {
			Repr::Utf8(s) => s.capacity(),
			Repr::Utf16(v) => v.capacity().saturating_mul(2),
		}
	}
	/// Borrow ordinary JSON source, escaping literal isolated surrogates only
	/// when necessary. An already escaped surrogate is an invalid JSON escape;
	/// do not repair it into a different valid string.
	pub(crate) fn json_source(&self) -> Option<alloc::borrow::Cow<'_, str>> {
		if let Some(text) = self.as_str() {
			return Some(alloc::borrow::Cow::Borrowed(text));
		}
		let mut out = String::new();
		let mut escaped = false;
		for scalar in char::decode_utf16(self.utf16()) {
			match scalar {
				Ok(c) => {
					out.push(c);
					escaped = c == '\\' && !escaped;
				}
				Err(e) => {
					if escaped {
						return None;
					}
					write!(out, "\\u{:04x}", e.unpaired_surrogate()).ok()?;
				}
			}
		}
		Some(alloc::borrow::Cow::Owned(out))
	}
	/// The scalar-string view used by JavaScript URL parsing and TextEncoder.
	/// Use only at those syntax boundaries; stored document text stays lossless.
	pub(crate) fn utf8_lossy(&self) -> alloc::borrow::Cow<'_, str> {
		match &self.0 {
			Repr::Utf8(text) => alloc::borrow::Cow::Borrowed(text),
			Repr::Utf16(units) => alloc::borrow::Cow::Owned(String::from_utf16_lossy(units)),
		}
	}
	pub fn from_utf16(units: &[u16]) -> Self {
		match String::from_utf16(units) {
			Ok(text) => text.into(),
			Err(_) => Self(Repr::Utf16(units.to_vec())),
		}
	}

	pub fn as_str(&self) -> Option<&str> {
		match &self.0 {
			Repr::Utf8(text) => Some(text),
			Repr::Utf16(_) => None,
		}
	}

	pub fn utf16(&self) -> impl Iterator<Item = u16> + '_ {
		let (text, units) = match &self.0 {
			Repr::Utf8(text) => (text.as_str(), [].as_slice()),
			Repr::Utf16(units) => ("", units.as_slice()),
		};
		text.encode_utf16().chain(units.iter().copied())
	}

	pub fn clear(&mut self) {
		self.0 = Repr::Utf8(String::new());
	}

	fn from_wtf8(mut bytes: &[u8]) -> Result<Self, &'static str> {
		if let Ok(text) = core::str::from_utf8(bytes) {
			return Ok(text.into());
		}
		let mut units = Vec::new();
		loop {
			match core::str::from_utf8(bytes) {
				Ok(text) => {
					units.extend(text.encode_utf16());
					break;
				}
				Err(error) => {
					let (prefix, rest) = bytes.split_at(error.valid_up_to());
					units.extend(
						core::str::from_utf8(prefix)
							.map_err(|_| "invalid text prefix")?
							.encode_utf16(),
					);
					// serde_json decodes escaped lone surrogates as WTF-8 when
					// asked for bytes. No other invalid UTF-8 sequence is text.
					if rest.len() < 3
						|| rest[0] != 0xed || !(0xa0..=0xbf).contains(&rest[1])
						|| !(0x80..=0xbf).contains(&rest[2])
					{
						return Err("invalid document text");
					}
					units.push(0xd000 | (u16::from(rest[1] & 0x3f) << 6) | u16::from(rest[2] & 0x3f));
					bytes = &rest[3..];
				}
			}
		}
		Ok(Self(Repr::Utf16(units)))
	}
}

impl<'de> Deserialize<'de> for DocumentText {
	fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
		struct TextVisitor;
		impl<'de> Visitor<'de> for TextVisitor {
			type Value = DocumentText;
			fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
				formatter.write_str("a JSON string")
			}
			fn visit_bytes<E: Error>(self, value: &[u8]) -> Result<DocumentText, E> {
				DocumentText::from_wtf8(value).map_err(E::custom)
			}
			fn visit_str<E: Error>(self, value: &str) -> Result<DocumentText, E> {
				Ok(value.into())
			}
		}
		deserializer.deserialize_bytes(TextVisitor)
	}
}

impl Serialize for DocumentText {
	fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
		match &self.0 {
			Repr::Utf8(text) => serializer.serialize_str(text),
			Repr::Utf16(units) => {
				let mut json = String::with_capacity(2 + units.len());
				json.push('"');
				let mut run = String::new();
				for scalar in char::decode_utf16(units.iter().copied()) {
					match scalar {
						Ok(c) => run.push(c),
						Err(e) => {
							append_json_run(&mut json, &mut run).map_err(serde::ser::Error::custom)?;
							write!(json, "\\u{:04x}", e.unpaired_surrogate()).map_err(serde::ser::Error::custom)?;
						}
					}
				}
				append_json_run(&mut json, &mut run).map_err(serde::ser::Error::custom)?;
				json.push('"');
				serde_json::value::RawValue::from_string(json)
					.map_err(serde::ser::Error::custom)?
					.serialize(serializer)
			}
		}
	}
}

fn append_json_run(json: &mut String, run: &mut String) -> Result<(), serde_json::Error> {
	if !run.is_empty() {
		let encoded = serde_json::to_string(run)?;
		json.push_str(&encoded[1..encoded.len() - 1]);
		run.clear();
	}
	Ok(())
}

pub(crate) fn js_whitespace(c: char) -> bool {
	matches!(c, '\u{0009}'..='\u{000d}' | ' ' | '\u{00a0}' | '\u{1680}'
		| '\u{2000}'..='\u{200a}' | '\u{2028}' | '\u{2029}' | '\u{202f}'
		| '\u{205f}' | '\u{3000}' | '\u{feff}')
}

impl PartialOrd for DocumentText {
	fn partial_cmp(&self, other: &Self) -> Option<core::cmp::Ordering> {
		Some(self.cmp(other))
	}
}
impl Ord for DocumentText {
	fn cmp(&self, other: &Self) -> core::cmp::Ordering {
		self.utf16().cmp(other.utf16())
	}
}
impl DocumentText {
	pub fn lowercase(&self) -> Self {
		if let Some(text) = self.as_str() {
			return text.to_lowercase().into();
		}
		let mut result = Vec::new();
		let mut run = String::new();
		for scalar in char::decode_utf16(self.utf16()) {
			match scalar {
				Ok(c) => run.push(c),
				Err(e) => {
					result.extend(run.to_lowercase().encode_utf16());
					run.clear();
					result.push(e.unpaired_surrogate());
				}
			}
		}
		result.extend(run.to_lowercase().encode_utf16());
		Self::from_utf16(&result)
	}
	pub(crate) fn trim_js(&mut self) {
		match &mut self.0 {
			Repr::Utf8(text) => {
				let start = text.len() - text.trim_start_matches(js_whitespace).len();
				let end = text.trim_end_matches(js_whitespace).len().max(start);
				text.truncate(end);
				text.drain(..start);
			}
			Repr::Utf16(units) => {
				let white = |v: &u16| char::from_u32(u32::from(*v)).is_some_and(js_whitespace);
				let start = units.iter().take_while(|v| white(v)).count();
				let end = units.len() - units.iter().rev().take_while(|v| white(v)).count();
				units.truncate(end.max(start));
				units.drain(..start);
			}
		}
	}
}
