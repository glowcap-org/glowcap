//! The names present on the IRC side of a bridged room.
//!
//! Two rosters meet in a bridged room and only one of them is this: the
//! Rooms members are the bridge's own table, and these are the people on the
//! channel who have no Rooms membership at all. They stay apart because they
//! have different lifetimes: an IRC roster is scoped to one IRC connection
//! and dropped whole when that connection ends, while a Rooms member
//! outlives it. Every change answers with what happened and the room says
//! it, because a line about somebody joining is the room's voice.
use super::{protocol::fold, seat::PREFIX};
use crate::room::inbox::{MAX_NICK, nick_refusal};
use alloc::{
	collections::BTreeMap,
	string::{String, ToString},
	vec::Vec,
};

/// How many IRC names one bridged room will carry. A larger channel is not
/// refused. Its roster is, because a roster crosses the wire whole.
pub const ROSTER_LIMIT: usize = 256;

/// How an IRC nick is written as a name in the room's own namespace. A name
/// that will not fit is refused rather than shortened, because shortening
/// merges identities.
pub fn display_nick(nick: &str) -> Result<String, Invalid> {
	let display = alloc::format!("{PREFIX}{nick}");
	if display.encode_utf16().count() > MAX_NICK || nick_refusal(&display).is_some() {
		return Err(Invalid::NickUnrepresentable { nick: nick.into() });
	}
	Ok(display)
}

#[derive(Debug, Default)]
pub struct Roster {
	nicks: BTreeMap<String, String>,
}

impl Roster {
	pub fn len(&self) -> usize {
		self.nicks.len()
	}
	pub fn is_empty(&self) -> bool {
		self.nicks.is_empty()
	}
	/// Every name, as written.
	pub fn names(&self) -> impl Iterator<Item = &str> {
		self.nicks.values().map(String::as_str)
	}
	/// Take one name. Answers the name as shown when it was not already
	/// here, `None` when it was, so a caller announces an arrival once.
	pub fn add(&mut self, nick: &str) -> Result<Option<String>, Invalid> {
		let display = display_nick(nick)?;
		let folded = fold(&display);
		if self.nicks.contains_key(&folded) {
			return Ok(None);
		}
		if self.nicks.len() >= ROSTER_LIMIT {
			return Err(Invalid::RosterFull);
		}
		self.nicks.insert(folded, display.clone());
		Ok(Some(display))
	}
	/// Drop one name, answering it as it was shown, or `None` when this
	/// roster never had it.
	pub fn remove(&mut self, nick: &str) -> Option<String> {
		let display = display_nick(nick).ok()?;
		self.nicks.remove(&fold(&display))
	}
	/// One name becoming another: both halves, so the room can say a rename
	/// as the departure and arrival every client draws. `None` when this
	/// roster does not hold the old name.
	pub fn rename(&mut self, from: &str, to: &str) -> Result<Option<(String, String)>, Invalid> {
		let Some(was) = display_nick(from)
			.ok()
			.and_then(|display| self.nicks.remove(&fold(&display)))
		else {
			return Ok(None);
		};
		let now = display_nick(to)?;
		self.nicks.insert(fold(&now), now.clone());
		Ok(Some((was, now)))
	}
	/// Take a whole roster in place of this one: what a NAMES reply is, a
	/// statement of everybody rather than a change to anybody.
	pub fn replace(&mut self, next: BTreeMap<String, String>) {
		self.nicks = next;
	}
	/// Forget everybody. Answers whether there was anybody, so a connection
	/// ending twice does not announce an empty roster twice.
	pub fn clear(&mut self) -> bool {
		if self.nicks.is_empty() {
			return false;
		}
		self.nicks.clear();
		true
	}
	/// A NAMES reply under assembly: names folded to their display form,
	/// refused past the roster limit.
	pub fn assemble(pending: &mut BTreeMap<String, String>, nick: &str) -> Result<(), Invalid> {
		let display = display_nick(nick)?;
		let folded = fold(&display);
		if !pending.contains_key(&folded) && pending.len() >= ROSTER_LIMIT {
			return Err(Invalid::RosterFull);
		}
		pending.insert(folded, display);
		Ok(())
	}
	pub fn sorted_names(&self) -> Vec<String> {
		let mut names: Vec<String> = self.names().map(String::from).collect();
		names.sort();
		names
	}
}

/// Why a nick or roster change is refused. `Display` is the exact line the
/// room reports.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Invalid {
	/// The nick cannot be written as a Rooms name.
	NickUnrepresentable { nick: String },
	/// The roster is at its limit.
	RosterFull,
}

impl core::fmt::Display for Invalid {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		match self {
			Self::NickUnrepresentable { nick } => {
				write!(f, "IRC nickname cannot be represented safely in Rooms: {nick:?}")
			}
			Self::RosterFull => write!(f, "IRC roster exceeds {ROSTER_LIMIT} names"),
		}
	}
}

impl core::error::Error for Invalid {}

/// A roster line is plain text to the peer: no failure code applies.
impl From<Invalid> for crate::server::Refusal {
	fn from(invalid: Invalid) -> Self {
		Self::plain(invalid)
	}
}
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
		assert_eq!(
			Invalid::NickUnrepresentable { nick: "a b".into() }.to_string(),
			"IRC nickname cannot be represented safely in Rooms: \"a b\""
		);
		assert_eq!(Invalid::RosterFull.to_string(), "IRC roster exceeds 256 names");
	}

	#[test]
	fn names_are_prefixed_folded_and_bounded() {
		let mut roster = Roster::default();
		assert_eq!(roster.add("Alice").unwrap().as_deref(), Some("irc/Alice"));
		assert_eq!(roster.add("alice").unwrap(), None);
		assert_eq!(
			roster.rename("ALICE", "bob").unwrap(),
			Some(("irc/Alice".into(), "irc/bob".into()))
		);
		assert_eq!(roster.remove("Bob").as_deref(), Some("irc/bob"));
		assert!(roster.remove("nobody").is_none());
		assert!(display_nick(&"x".repeat(MAX_NICK)).is_err());
		assert!(!roster.clear());
		roster.add("c").unwrap();
		assert!(roster.clear());
	}

	#[test]
	fn the_roster_refuses_growth_past_its_limit() {
		let mut roster = Roster::default();
		for at in 0..ROSTER_LIMIT {
			roster.add(&alloc::format!("n{at}")).unwrap();
		}
		assert!(roster.add("one-more").is_err());
	}
}
