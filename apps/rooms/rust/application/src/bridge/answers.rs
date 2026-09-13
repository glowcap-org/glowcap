//! Bounded bridge-form answers preserve declared field identities.
use super::{Error as BridgeError, MAX_FIELDS, MAX_FORM_VALUE};
use crate::fields::Text;
use crate::text::DocumentText;
use alloc::{string::String, vec::Vec};
use core::fmt;
use serde::{
	Deserialize, Deserializer, Serialize, Serializer,
	de::{Error, Visitor},
};

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct Id(String);
impl Id {
	fn accepts(value: &str) -> bool {
		value.len() <= 32
			&& value.as_bytes().first().is_some_and(u8::is_ascii_lowercase)
			&& value
				.bytes()
				.all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
	}
	pub fn new(value: String) -> Option<Self> {
		Self::accepts(&value).then_some(Self(value))
	}
	pub fn as_str(&self) -> &str {
		&self.0
	}
}
impl<'de> Deserialize<'de> for Id {
	fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
		Self::new(String::deserialize(d)?).ok_or_else(|| D::Error::custom("bridge identifier"))
	}
}

// Answer names are nonnumeric ASCII keys. Preserve insertion order: durable
// retry digests include JSON.stringify(checkpoint), not just its abstract map.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Answers(Vec<(alloc::string::String, Text<MAX_FORM_VALUE>)>);
impl Answers {
	pub fn decode(raw: &str) -> Result<Self, BridgeError> {
		super::check_size(raw)?;
		serde_json::from_str(raw).map_err(|_| BridgeError::Answers)
	}
	pub fn encode(&self) -> Result<String, BridgeError> {
		let raw = serde_json::to_string(self).map_err(|_| BridgeError::Answers)?;
		super::check_size(&raw)?;
		Ok(raw)
	}
	pub fn get(&self, key: &str) -> Option<&DocumentText> {
		self.0.iter().find(|(id, _)| id == key).map(|(_, value)| value.text())
	}
	pub fn iter(&self) -> impl ExactSizeIterator<Item = (&str, &DocumentText)> {
		self.0.iter().map(|(id, value)| (id.as_str(), value.text()))
	}
	/// Existing keys keep their insertion position, matching JSON object updates.
	pub fn insert(&mut self, key: String, value: DocumentText) -> Result<(), BridgeError> {
		if !Id::accepts(&key) {
			return Err(BridgeError::Answers);
		}
		let value = Text::new(value).ok_or(BridgeError::Answers)?;
		if let Some((_, held)) = self.0.iter_mut().find(|(id, _)| id == &key) {
			*held = value;
		} else {
			if self.0.len() == MAX_FIELDS * 2 {
				return Err(BridgeError::Answers);
			}
			self.0.push((key, value));
		}
		Ok(())
	}
	pub(super) fn partition(self, secret: impl Fn(&str) -> bool) -> (Self, Self) {
		let (secrets, public) = self.0.into_iter().partition(|(id, _)| secret(id));
		(Self(public), Self(secrets))
	}
	pub fn retained_bytes(&self) -> usize {
		self.0.iter().fold(
			self.0
				.capacity()
				.saturating_mul(core::mem::size_of::<(alloc::string::String, Text<MAX_FORM_VALUE>)>()),
			|sum, (key, value)| {
				sum.saturating_add(key.capacity())
					.saturating_add(value.text().heap_bytes())
			},
		)
	}
	pub(crate) fn heap_bytes(&self) -> usize {
		self.retained_bytes()
	}
	pub fn is_empty(&self) -> bool {
		self.0.is_empty()
	}
}
impl Serialize for Answers {
	fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
		use serde::ser::SerializeMap;
		let mut map = s.serialize_map(Some(self.0.len()))?;
		for (key, value) in &self.0 {
			map.serialize_entry(key, value)?;
		}
		map.end()
	}
}
impl<'de> Deserialize<'de> for Answers {
	fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
		struct Read;
		impl<'de> Visitor<'de> for Read {
			type Value = Answers;
			fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
				f.write_str("bounded bridge answers")
			}
			fn visit_map<A: serde::de::MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
				// JSON.parse replaces duplicate properties before schema validation.
				// Borrow their raw values until the final occurrence is known, so an
				// overwritten value is neither validated nor allocated as answer text.
				let mut answers: Vec<(String, &'de serde_json::value::RawValue)> = Vec::new();
				while let Some(key) = map.next_key::<alloc::string::String>()? {
					if !Id::accepts(&key)
						|| (answers.len() == MAX_FIELDS * 2 && !answers.iter().any(|(held, _)| held == &key))
					{
						return Err(A::Error::custom("bridge answer key or limit"));
					}
					let value = map.next_value()?;
					if let Some((_, held)) = answers.iter_mut().find(|(held, _)| held == &key) {
						*held = value;
					} else {
						answers.push((key, value));
					}
				}
				answers
					.into_iter()
					.map(|(key, raw)| {
						serde_json::from_str(raw.get())
							.map(|value| (key, value))
							.map_err(A::Error::custom)
					})
					.collect::<Result<Vec<_>, _>>()
					.map(Answers)
			}
		}
		d.deserialize_map(Read)
	}
}
