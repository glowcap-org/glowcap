//! Bounded JSON fields shared by Rooms forms and durable documents.
pub(crate) mod footprint;
mod hex;
use crate::text::DocumentText;
use alloc::{boxed::Box, vec::Vec};
use core::fmt;
pub use hex::lower_hex;
pub(crate) use hex::Hex;
use serde::{
	Deserialize, Deserializer, Serialize,
	de::{Error, SeqAccess, Visitor},
};

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct Text<const N: usize, const NONEMPTY: bool = false>(pub(crate) DocumentText);
impl<'de, const N: usize, const NONEMPTY: bool> Deserialize<'de> for Text<N, NONEMPTY> {
	fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
		let value = DocumentText::deserialize(d)?;
		if !Self::accepts_utf16(value.utf16()) {
			return Err(D::Error::custom("Rooms text length"));
		}
		Ok(Self(value))
	}
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct List<T, const N: usize>(pub(crate) Vec<T>);
impl<'de, T: Deserialize<'de>, const N: usize> Deserialize<'de> for List<T, N> {
	fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
		struct Read<T, const N: usize>(core::marker::PhantomData<T>);
		impl<'de, T: Deserialize<'de>, const N: usize> Visitor<'de> for Read<T, N> {
			type Value = List<T, N>;
			fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
				f.write_str("bounded Rooms list")
			}
			fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Self::Value, A::Error> {
				let mut values = Vec::new();
				while values.len() < N {
					let Some(value) = seq.next_element()? else {
						return Ok(List(values));
					};
					values.push(value);
				}
				if seq.next_element::<serde::de::IgnoredAny>()?.is_some() {
					return Err(A::Error::custom("Rooms list limit"));
				}
				Ok(List(values))
			}
		}
		d.deserialize_seq(Read::<T, N>(core::marker::PhantomData))
	}
}

pub fn present<'de, T: Deserialize<'de>, D: Deserializer<'de>>(d: D) -> Result<Option<T>, D::Error> {
	T::deserialize(d).map(Some)
}

/// JSON records require maps. Serde's derived struct reader also accepts
/// positional arrays; that is not part of the Rooms JSON contract. Forward
/// the original map access so fields still borrow the source and RawValue
/// preserves isolated UTF-16 surrogates without an intermediate value tree.
pub(crate) fn object<'de, T: Deserialize<'de>, D: Deserializer<'de>>(d: D) -> Result<T, D::Error> {
	struct Read<T>(core::marker::PhantomData<T>);
	impl<'de, T: Deserialize<'de>> Visitor<'de> for Read<T> {
		type Value = T;
		fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
			f.write_str("Rooms JSON object")
		}
		fn visit_map<A: serde::de::MapAccess<'de>>(self, map: A) -> Result<T, A::Error> {
			T::deserialize(serde::de::value::MapAccessDeserializer::new(map))
		}
	}
	d.deserialize_map(Read(core::marker::PhantomData))
}
pub(crate) fn present_object<'de, T: Deserialize<'de>, D: Deserializer<'de>>(d: D) -> Result<Option<T>, D::Error> {
	object(d).map(Some)
}
pub(crate) fn json_object<'de, T: Deserialize<'de>>(raw: &'de str) -> Result<T, serde_json::Error> {
	let mut reader = serde_json::Deserializer::from_str(raw);
	let value = object(&mut reader)?;
	reader.end()?;
	Ok(value)
}

/// Exact unsigned JSON integer admission for identity and version fields.
/// Decimal and exponent spellings remain compatible with JavaScript numbers,
/// but no value is rounded through binary floating point before admission.
pub(crate) fn json_u64<'de, D: Deserializer<'de>>(d: D) -> Result<u64, D::Error> {
	let raw = Box::<serde_json::value::RawValue>::deserialize(d)?;
	exact_json_u64(raw.get()).ok_or_else(|| D::Error::custom("unsigned integer"))
}

fn exact_json_u64(raw: &str) -> Option<u64> {
	let (negative, raw) = match raw.strip_prefix('-') {
		Some(raw) => (true, raw),
		None => (false, raw),
	};
	let (coefficient, exponent) = raw.split_once(['e', 'E']).unwrap_or((raw, "0"));
	let exponent_digits = exponent.strip_prefix(['+', '-']).unwrap_or(exponent);
	if exponent_digits.is_empty() || !exponent_digits.bytes().all(|digit| digit.is_ascii_digit()) {
		return None;
	}
	let (whole, fraction) = coefficient.split_once('.').unwrap_or((coefficient, ""));
	if whole.is_empty()
		|| (coefficient.contains('.') && fraction.is_empty())
		|| !whole
			.bytes()
			.chain(fraction.bytes())
			.all(|digit| digit.is_ascii_digit())
	{
		return None;
	}
	if whole.bytes().chain(fraction.bytes()).all(|digit| digit == b'0') {
		return Some(0);
	}
	if negative {
		return None;
	}
	let exponent = exponent.parse::<i64>().ok()?;
	let fractional = i64::try_from(fraction.len()).ok()?;
	let scale = fractional.checked_sub(exponent)?;
	let digits = whole.bytes().chain(fraction.bytes());
	let digit_count = whole.len().checked_add(fraction.len())?;
	let kept = if scale > 0 {
		let discarded = usize::try_from(scale).ok()?;
		if discarded > digit_count || !digits.clone().skip(digit_count - discarded).all(|digit| digit == b'0') {
			return None;
		}
		digit_count - discarded
	} else {
		digit_count
	};
	let mut value = 0_u64;
	for digit in digits.take(kept) {
		value = value.checked_mul(10)?.checked_add(u64::from(digit - b'0'))?;
	}
	let appended = if scale < 0 {
		usize::try_from(scale.checked_neg()?).ok()?
	} else {
		0
	};
	for _ in 0..appended {
		value = value.checked_mul(10)?;
	}
	Some(value)
}

/// An object inside a JSON collection. Its representation is exactly `T`;
/// admission keeps the map-only contract at each nested record boundary.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct Object<T>(pub T);
impl<'de, T: Deserialize<'de>> Deserialize<'de> for Object<T> {
	fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
		object(d).map(Self)
	}
}
impl<T> core::ops::Deref for Object<T> {
	type Target = T;
	fn deref(&self) -> &T {
		&self.0
	}
}
pub(crate) fn object_list<'de, T: Deserialize<'de>, D: Deserializer<'de>, const N: usize>(
	d: D,
) -> Result<List<T, N>, D::Error> {
	struct Read<T, const N: usize>(core::marker::PhantomData<T>);
	impl<'de, T: Deserialize<'de>, const N: usize> Visitor<'de> for Read<T, N> {
		type Value = List<T, N>;
		fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
			f.write_str("bounded list of Rooms objects")
		}
		fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Self::Value, A::Error> {
			let mut out = Vec::new();
			while out.len() < N {
				let Some(Object(value)) = seq.next_element()? else {
					return Ok(List(out));
				};
				out.push(value);
			}
			if seq.next_element::<serde::de::IgnoredAny>()?.is_some() {
				return Err(A::Error::custom("Rooms list limit"));
			}
			Ok(List(out))
		}
	}
	d.deserialize_seq(Read::<T, N>(core::marker::PhantomData))
}
pub(crate) fn required_nullable<'de, T: serde::de::DeserializeOwned, D: Deserializer<'de>>(
	d: D,
) -> Result<Option<T>, D::Error> {
	Ok(match Nullable::deserialize(d)? {
		Nullable::Value(value) => Some(value),
		Nullable::Null => None,
	})
}

impl<const N: usize, const NONEMPTY: bool> Text<N, NONEMPTY> {
	pub fn accepts_utf16(units: impl Iterator<Item = u16>) -> bool {
		let count = units.take(N.saturating_add(1)).count();
		count <= N && (!NONEMPTY || count > 0)
	}
	pub fn new(value: DocumentText) -> Option<Self> {
		Self::accepts_utf16(value.utf16()).then_some(Self(value))
	}
	pub fn text(&self) -> &DocumentText {
		&self.0
	}
}
impl<T, const N: usize> List<T, N> {
	pub fn try_push(&mut self, value: T) -> Result<(), T> {
		if self.0.len() >= N {
			return Err(value);
		}
		self.0.push(value);
		Ok(())
	}
	pub fn new(values: Vec<T>) -> Option<Self> {
		(values.len() <= N).then_some(Self(values))
	}
	pub fn as_slice(&self) -> &[T] {
		&self.0
	}
}

// Unlike Option, a required nullable field must refuse a missing property.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(untagged)]
pub enum Nullable<T> {
	Value(T),
	Null,
}
impl<'de, T: serde::de::DeserializeOwned> Deserialize<'de> for Nullable<T> {
	fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
		// Borrow the JSON instead of buffering serde Content, which requires
		// Unicode scalar strings and would discard JavaScript surrogate text.
		let raw = <&serde_json::value::RawValue>::deserialize(d)?;
		if raw.get() == "null" {
			return Ok(Self::Null);
		}
		serde_json::from_str(raw.get())
			.map(Self::Value)
			.map_err(D::Error::custom)
	}
}
impl<T> Nullable<T> {
	pub fn as_ref(&self) -> Option<&T> {
		match self {
			Self::Value(value) => Some(value),
			Self::Null => None,
		}
	}
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct SafeInteger<const POSITIVE: bool = false>(u64);
impl<const POSITIVE: bool> SafeInteger<POSITIVE> {
	pub fn new(value: u64) -> Option<Self> {
		(value < (1u64 << 53) && (!POSITIVE || value > 0)).then_some(Self(value))
	}
	pub fn get(self) -> u64 {
		self.0
	}
}
impl<'de, const POSITIVE: bool> Deserialize<'de> for SafeInteger<POSITIVE> {
	fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
		let value = json_u64(d).map_err(|_| D::Error::custom("safe integer"))?;
		Self::new(value).ok_or_else(|| D::Error::custom("safe integer"))
	}
}

#[cfg(test)]
mod tests {
	use super::{SafeInteger, exact_json_u64};
	use serde::Deserialize;

	#[derive(Deserialize)]
	struct Nested {
		value: SafeInteger,
	}

	#[test]
	fn safe_integer_json_admission_is_exact() {
		assert_eq!(exact_json_u64("18446744073709551615"), Some(u64::MAX));
		assert_eq!(exact_json_u64("18446744073709551616"), None);
		assert_eq!(exact_json_u64("-0.0e999999999999999999999"), Some(0));
		assert_eq!(exact_json_u64("true"), None);
		let read = |raw| serde_json::from_str::<SafeInteger>(raw).map(SafeInteger::get);
		assert_eq!(read("0").unwrap(), 0);
		assert_eq!(read("1.0").unwrap(), 1);
		assert_eq!(read("1e1").unwrap(), 10);
		assert_eq!(read("10e-1").unwrap(), 1);
		assert_eq!(read("0.1e1").unwrap(), 1);
		assert_eq!(read("9007199254740991").unwrap(), (1_u64 << 53) - 1);
		for raw in ["-1", "1e-1", "1.00000000000000001", "9007199254740992"] {
			assert!(read(raw).is_err(), "admitted non-safe integer {raw}");
		}
		assert!(serde_json::from_str::<SafeInteger<true>>("0").is_err());
		assert_eq!(serde_json::from_str::<SafeInteger<true>>("1").unwrap().get(), 1);
		assert_eq!(serde_json::from_str::<Nested>(r#"{"value":3}"#).unwrap().value.get(), 3);
	}
}
