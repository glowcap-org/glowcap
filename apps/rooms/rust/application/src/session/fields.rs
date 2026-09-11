pub use crate::bridge::Answers;
pub use crate::fields::{present, List, Nullable, SafeInteger, Text};
use serde::{de::Error, Deserialize, Deserializer, Serialize, Serializer};

pub type Field = Text<65536>;
pub type Id = Text<65536, true>;
pub type Bearer = Text<16384>;

pub fn version<'de, D: Deserializer<'de>>(d: D) -> Result<u8, D::Error> {
	if f64::deserialize(d)? == 1.0 {
		Ok(1)
	} else {
		Err(D::Error::custom("checkpoint version"))
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
