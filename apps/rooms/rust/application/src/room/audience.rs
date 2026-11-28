//! The named audience one sender chooses for newly composed lines in one room.
use super::inbox::{MAX_NICK, nick_key, valid_nick};
use crate::{
	fields::{List, Text, footprint::HeapBytes},
	markdown::{Document, Node},
};
use alloc::{collections::BTreeSet, format, string::String};
use serde::{Deserialize, Deserializer, Serialize, de::Error};

pub const MAX_ROOM_AUDIENCE: usize = 32;
type Name = Text<MAX_NICK, true>;
pub type Names = List<Name, MAX_ROOM_AUDIENCE>;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct Audience(Names);

/// The room permits names that cannot be written as one Markdown mention.
pub fn addressable(name: &str) -> bool {
	if !valid_nick(name) {
		return false;
	}
	let line = Document::read(&format!("@{name}"));
	matches!(line.blocks.as_slice(), [Node::Paragraph { children }]
		if matches!(children.as_slice(), [Node::Mention { name: read, room: false }] if read == name))
}

impl Audience {
	pub fn from_names(names: &[&str]) -> Option<Self> {
		let mut fields = Names::default();
		for &name in names {
			fields.try_push(Name::new(name.into())?).ok()?;
		}
		Self::checked(fields)
	}
	fn checked(fields: Names) -> Option<Self> {
		let mut seen = BTreeSet::new();
		for name in fields.as_slice() {
			let name = name.text().as_str()?;
			if !addressable(name) || !seen.insert(nick_key(name)) {
				return None;
			}
		}
		Some(Self(fields))
	}
	pub fn is_empty(&self) -> bool {
		self.0.is_empty()
	}
	pub fn names(&self) -> impl Iterator<Item = &str> {
		self.0.as_slice().iter().filter_map(|name| name.text().as_str())
	}
	pub(crate) fn prefix(&self) -> String {
		let mut prefix = String::new();
		for name in self.names() {
			if !prefix.is_empty() {
				prefix.push(' ');
			}
			prefix.push('@');
			prefix.push_str(name);
		}
		prefix
	}
}

impl<'de> Deserialize<'de> for Audience {
	fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
		Self::checked(Names::deserialize(deserializer)?).ok_or_else(|| D::Error::custom("invalid room audience"))
	}
}

impl HeapBytes for Audience {
	fn heap_bytes(&self) -> usize {
		self.0.heap_bytes()
	}
}
