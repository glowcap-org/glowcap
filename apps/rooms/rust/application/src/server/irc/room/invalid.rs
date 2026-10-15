//! Why a bridged room is refused at creation. `Display` of each variant is
//! the exact line the operator reads.
use crate::server::rooms::MAX_ROOM;
use alloc::string::{String, ToString};
use core::fmt;

/// A refused network, channel, publication identity, origin, or room name.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Invalid {
	/// The network name is not letters, digits, dots, and hyphens.
	NetworkName,
	/// The channel is not a well-formed IRC channel.
	Channel,
	/// The publication identity is empty or over `MAX_PUBLICATION_ID` bytes.
	PublicationIdentity,
	/// The origin is empty or over `MAX_ORIGIN` bytes.
	Origin,
	/// The room name `network/channel` is over the room name limit.
	RoomNameLength,
}

impl fmt::Display for Invalid {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::NetworkName => f.write_str("IRC network name uses letters, digits, dots, and hyphens"),
			Self::Channel => f.write_str("IRC bridge channel is malformed"),
			Self::PublicationIdentity => f.write_str("IRC bridge publication identity is malformed"),
			Self::Origin => f.write_str("IRC bridge origin is malformed"),
			Self::RoomNameLength => write!(f, "the bridged room name may be at most {MAX_ROOM} characters"),
		}
	}
}

impl core::error::Error for Invalid {}

impl From<Invalid> for String {
	fn from(invalid: Invalid) -> Self {
		invalid.to_string()
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn every_invalid_line_is_the_line_it_replaced() {
		let lines = [
			(
				Invalid::NetworkName,
				"IRC network name uses letters, digits, dots, and hyphens",
			),
			(Invalid::Channel, "IRC bridge channel is malformed"),
			(
				Invalid::PublicationIdentity,
				"IRC bridge publication identity is malformed",
			),
			(Invalid::Origin, "IRC bridge origin is malformed"),
			(
				Invalid::RoomNameLength,
				"the bridged room name may be at most 32 characters",
			),
		];
		for (invalid, line) in lines {
			assert_eq!(invalid.to_string(), line);
		}
	}
}
