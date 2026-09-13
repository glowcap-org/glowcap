//! Session wire fields share bounded forms with application policy.
pub use crate::bridge::Answers;
pub use crate::fields::{List, Nullable, SafeInteger, Text, present};
use serde::{Deserialize, Deserializer, Serialize, Serializer, de::Error};

pub type Field = Text<65536>;
pub type Id = Text<65536, true>;
pub type Bearer = Text<16384>;

pub fn version<'de, D: Deserializer<'de>>(d: D) -> Result<u8, D::Error> {
	if crate::fields::json_u64(d)? == 1 {
		Ok(1)
	} else {
		Err(D::Error::custom("checkpoint version"))
	}
}

#[cfg(test)]
mod tests {
	use serde::Deserialize;

	#[derive(Deserialize)]
	struct Document {
		#[serde(deserialize_with = "super::version")]
		version: u8,
	}

	#[test]
	fn checkpoint_version_is_an_exact_integer() {
		for raw in [r#"{"version":1}"#, r#"{"version":1.0}"#, r#"{"version":1e0}"#] {
			assert_eq!(serde_json::from_str::<Document>(raw).unwrap().version, 1);
		}
		let rounded = r#"{"version":1.00000000000000001}"#;
		assert!(
			serde_json::from_str::<Document>(rounded).is_err(),
			"admitted inexact version {rounded}"
		);
	}
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum Presence<T> {
	#[default]
	Missing,
	Null,
	Value(T),
}
impl<T> Presence<T> {
	pub fn missing(&self) -> bool {
		matches!(self, Self::Missing)
	}
}
impl<T: Serialize> Serialize for Presence<T> {
	fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
		match self {
			Self::Value(v) => v.serialize(s),
			_ => s.serialize_none(),
		}
	}
}
impl<'de, T: serde::de::DeserializeOwned> Deserialize<'de> for Presence<T> {
	fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
		Ok(match Nullable::<T>::deserialize(d)? {
			Nullable::Value(v) => Self::Value(v),
			Nullable::Null => Self::Null,
		})
	}
}
pub(crate) use crate::directory::registration_id;
