//! Bounded JSON fields shared by Rooms forms and durable documents.
pub(crate) mod footprint;
mod hex;
use crate::text::DocumentText;
use alloc::vec::Vec;
use core::fmt;
pub(crate) use hex::Hex;
use serde::{
	de::{Error, SeqAccess, Visitor},
	Deserialize, Deserializer, Serialize,
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
		let n = f64::deserialize(d)?;
		let integer = n as u64;
		Self::new(integer)
			.filter(|_| n >= 0.0 && n == integer as f64)
			.ok_or_else(|| serde::de::Error::custom("safe integer"))
	}
}
