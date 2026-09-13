//! Rooms directory publications and client reply contracts above CapTP.
pub mod creation;
mod discovery;
pub mod introduction;
mod publication;
pub use discovery::{Event, MemberChange, RoomChange, Snapshot, event, event_fields, rooms, snapshot};
pub use publication::{Member, OriginProof, PublicationKind, RoomInfo};
pub mod queue;
pub mod registration;
pub mod wire;
pub use wire::Shape;

pub use crate::protocol_data::{DIRECTORY as NAME, LIST_PUBLICATIONS as LIST, WATCH_PUBLICATIONS as WATCH};
pub const MAX_ROWS: usize = 256;

pub use crate::room::ListArgument as Argument;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	List,
	Row,
	Snapshot,
	RecoveryKey,
	Capability,
	Bootstrap,
	Authorities,
	Link,
	Location,
	Overflow,
	Closed,
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::List => "the directory answered an invalid or oversized room list",
			Self::Row => "the directory answered an invalid room-list row",
			Self::Snapshot => "the directory answered an invalid watch snapshot",
			Self::RecoveryKey => "a room recovery key is invalid",
			Self::Capability => "the directory answered without a room capability",
			Self::Bootstrap => "the directory answered without room and bootstrap capabilities",
			Self::Authorities => "the room bootstrap answered incomplete authority",
			Self::Link => "the directory answered without a valid room sturdyref",
			Self::Location => "the directory answered without an advertised location",
			Self::Overflow => "the directory observer could not keep up; fetch a new snapshot",
			Self::Closed => "the directory observer has ended",
		})
	}
}
impl core::error::Error for Error {}

pub(crate) fn registration_id(text: &crate::text::DocumentText) -> bool {
	let Some(s) = text.as_str() else { return false };
	registration_id_text(s)
}
fn registration_id_text(s: &str) -> bool {
	if s == "00000000-0000-0000-0000-000000000000" || s == "ffffffff-ffff-ffff-ffff-ffffffffffff" {
		return true;
	}
	s.len() == 36
		&& s.bytes().enumerate().all(|(i, v)| match i {
			8 | 13 | 18 | 23 => v == b'-',
			14 => matches!(v, b'1'..=b'8'),
			19 => matches!(v, b'8' | b'9' | b'a' | b'b' | b'A' | b'B'),
			_ => v.is_ascii_hexdigit(),
		})
}
