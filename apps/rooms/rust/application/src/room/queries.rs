//! Replies available from a room entrance before any membership is acquired.
use super::{ArgumentView, authority::Reply, policy::RoomPolicy};

pub use crate::protocol_data::{CALLED, PRIVATE, ROOM_POLICY as POLICY};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	Privacy,
	Policy,
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Privacy => "the room did not say whether it is listed",
			Self::Policy => "the room answered an invalid policy",
		})
	}
}
impl core::error::Error for Error {}

pub fn called(reply: &impl ArgumentView) -> &str {
	reply.text().unwrap_or("")
}
pub fn is_private(reply: &impl ArgumentView) -> Result<bool, Error> {
	match (reply.boolean(), reply.text()) {
		(Some(true), _) | (_, Some("private")) => Ok(true),
		(Some(false), _) | (_, Some("" | "listed")) => Ok(false),
		_ => Err(Error::Privacy),
	}
}
pub fn policy(reply: &impl Reply) -> Result<RoomPolicy, Error> {
	if reply.list_len() != Some(3) {
		return Err(Error::Policy);
	}
	let [Some(visibility), Some(entry), Some(speaking)] = [reply.list_text(0), reply.list_text(1), reply.list_text(2)]
	else {
		return Err(Error::Policy);
	};
	RoomPolicy::parse(&[visibility, entry, speaking]).ok_or(Error::Policy)
}
