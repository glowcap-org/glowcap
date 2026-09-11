//! Portable Rooms archive records, scope, wire tuples and revision index.
//! Storage commitment and capability hosting belong to adapters.
use serde::{Deserialize, Serialize};
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ShareKind {
	Direct,
	Room,
	Standing,
}
impl ShareKind {
	pub fn parse(value: &str) -> Option<Self> {
		match value {
			"direct" => Some(Self::Direct),
			"room" => Some(Self::Room),
			"standing" => Some(Self::Standing),
			_ => None,
		}
	}
	pub const fn wire(self) -> &'static str {
		match self {
			Self::Direct => "direct",
			Self::Room => "room",
			Self::Standing => "standing",
		}
	}
}

pub mod attachment;
pub mod blobs;
pub mod change;
pub mod disk;
pub mod identity;
pub mod index;
pub mod merge;
pub mod output;
pub mod protocol;
pub mod recording;
pub mod records;
pub mod request;
pub mod retention;
pub mod scope;
mod serde_record;
pub mod shares;
pub use records::{Attachment, Body, ConversationKind, Coordinates, Kind, LineState, Record};
pub use scope::{Access, Facet, Filter};
pub const MAX_READ: usize = 128;
pub const MAX_RECORDS: usize = 5000;
pub const MAX_ID_BYTES: usize = 128;
pub const MAX_CONTEXT_BYTES: usize = 8192;
pub const MAX_CONVERSATION_BYTES: usize = 512;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	Record,
	Filter,
	Access,
	Revision,
	Capacity,
	Page,
	Method,
	Document,
	Blob,
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Blob => "archive attachment is unavailable or invalid",
			Self::Record => "invalid archive record",
			Self::Filter => "invalid or disjoint archive scope",
			Self::Access => "archive access cannot be widened",
			Self::Revision => "invalid archive revision",
			Self::Capacity => "archive record capacity exceeded",
			Self::Page => "invalid archive read page",
			Self::Document => "invalid archive document",
			Self::Method => "unknown archive method or invalid argument count",
		})
	}
}
impl core::error::Error for Error {}
