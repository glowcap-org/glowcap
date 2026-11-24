//! The outgoing mutation and reply contract captured by session admission.
use alloc::{string::String, vec::Vec};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reply {
	Acknowledgment,
	Boolean,
	Stewardship,
	RoomPolicy,
	RoomLink,
	RoomModerator,
	RoomManager,
	Line,
	Membership,
	ManagedRoom,
	PublicationLease,
	AcceptedAccess,
	Text,
	Listener,
	IrcConnection,
	DirectAccess,
	DirectoryRegistration,
	Upload,
	RetireBatch,
}
impl Reply {
	/// Whether a result of this kind may hand back a capability the session
	/// stores for the access that sent it. A kind that answers false settles
	/// with data only, and the runtime refuses such a settlement that carries
	/// a capability. `Line` and `Upload` answer true although each can settle
	/// with none: a post the room did not give a line reference, and an upload
	/// that posted no line, return data alone.
	pub const fn may_retain_capabilities(self) -> bool {
		match self {
			Self::Acknowledgment
			| Self::Boolean
			| Self::Stewardship
			| Self::RoomPolicy
			| Self::Text
			| Self::Listener
			| Self::RetireBatch => false,
			Self::RoomLink
			| Self::RoomModerator
			| Self::RoomManager
			| Self::Line
			| Self::Membership
			| Self::ManagedRoom
			| Self::PublicationLease
			| Self::AcceptedAccess
			| Self::IrcConnection
			| Self::DirectAccess
			| Self::DirectoryRegistration
			| Self::Upload => true,
		}
	}
}

/// Admitted mutation values contain data only. Held targets are captured
/// separately by the receipt and cannot be supplied through this grammar.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Argument {
	Text(String),
	Integer(i64),
	List(Vec<Argument>),
}
impl Argument {
	pub fn text(&self) -> Option<&str> {
		match self {
			Self::Text(value) => Some(value),
			_ => None,
		}
	}
}
impl crate::room::ArgumentView for Argument {
	fn boolean(&self) -> Option<bool> {
		None
	}
	fn is_null(&self) -> bool {
		false
	}
	fn text(&self) -> Option<&str> {
		self.text()
	}
	fn integer(&self) -> Option<i128> {
		match self {
			Self::Integer(value) => Some(i128::from(*value)),
			_ => None,
		}
	}
	fn float(&self) -> Option<f64> {
		None
	}
	fn contains_capability(&self) -> bool {
		false
	}
}
impl From<String> for Argument {
	fn from(value: String) -> Self {
		Self::Text(value)
	}
}
impl From<&str> for Argument {
	fn from(value: &str) -> Self {
		Self::Text(value.into())
	}
}
impl PartialEq<&str> for Argument {
	fn eq(&self, other: &&str) -> bool {
		self.text() == Some(*other)
	}
}
pub struct Mutation {
	pub verb: String,
	pub args: Vec<Argument>,
	pub reply: Reply,
}
