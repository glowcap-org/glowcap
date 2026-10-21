//! One committed registration result binds its name, identity and exact custody.
use crate::{
	fields::{Text, lower_hex},
	room::ArgumentView,
};
use alloc::{format, string::String};

/// How a directory should interpret the nickname carried by `register`.
/// Exact intent never changes the reader's choice. Automatic intent treats
/// the carried name as a base and atomically allocates the first free spelling.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NicknameAllocation {
	#[default]
	Exact,
	Automatic,
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase", deny_unknown_fields)]
pub enum NicknameIntent {
	Exact { name: String },
	Automatic { base: String },
}
impl NicknameIntent {
	pub fn requested(&self) -> &str {
		match self {
			Self::Exact { name } => name,
			Self::Automatic { base } => base,
		}
	}
	pub const fn allocation(&self) -> NicknameAllocation {
		match self {
			Self::Exact { .. } => NicknameAllocation::Exact,
			Self::Automatic { .. } => NicknameAllocation::Automatic,
		}
	}
}
impl NicknameAllocation {
	pub const fn wire(self) -> &'static str {
		match self {
			Self::Exact => "exact",
			Self::Automatic => "automatic",
		}
	}
	pub fn parse(value: &str) -> Option<Self> {
		match value {
			"exact" => Some(Self::Exact),
			"automatic" => Some(Self::Automatic),
			_ => None,
		}
	}
}

/// The next conventional spelling for an occupied name. This is application
/// policy shared by authoritative allocation and read-only UI projections.
pub fn suggested_nick(nick: &str) -> String {
	use core::fmt::Write;
	let (base, next) = match nick.rsplit_once('-') {
		Some((base, suffix)) if !suffix.is_empty() && suffix.bytes().all(|byte| byte.is_ascii_digit()) => (
			base,
			suffix
				.parse::<u64>()
				.ok()
				.and_then(|number| number.checked_add(1))
				.unwrap_or(2),
		),
		_ => (nick, 2),
	};
	let suffix = alloc::format!("-{next}");
	let keep = crate::room::inbox::MAX_NICK.saturating_sub(suffix.encode_utf16().count());
	let mut answer = String::new();
	let mut used = 0;
	for character in base.chars() {
		if used + character.len_utf16() > keep {
			break;
		}
		answer.push(character);
		used += character.len_utf16();
	}
	let _ = write!(answer, "{suffix}");
	answer
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum NicknameAvailability {
	Unknown,
	Available,
	Taken { source: &'static str, suggestion: String },
}

/// Project what current discovery evidence proves about an exact nickname.
/// `None` means that source is not known. `Some` means the supplied view is a
/// usable snapshot. Submission still races safely against directory allocation.
pub fn nickname_availability<'a>(
	nick: &str,
	own: Option<&str>,
	directory: Option<impl IntoIterator<Item = &'a str>>,
	room: Option<impl IntoIterator<Item = &'a str>>,
) -> NicknameAvailability {
	use alloc::collections::BTreeSet;
	if nick.is_empty() {
		return NicknameAvailability::Unknown;
	}
	if own.is_some_and(|own| own.eq_ignore_ascii_case(nick)) {
		return NicknameAvailability::Available;
	}
	let mut occupied = BTreeSet::new();
	let requested = nick.to_lowercase();
	let mut directory_taken = false;
	let room_known = room.is_some();
	if let Some(names) = directory {
		for name in names {
			let folded = name.to_lowercase();
			directory_taken |= folded == requested;
			occupied.insert(folded);
		}
	}
	if let Some(names) = room {
		for name in names {
			occupied.insert(name.to_lowercase());
		}
	}
	if occupied.contains(&requested) {
		let mut suggestion = suggested_nick(nick);
		for _ in 0..=occupied.len() {
			if !occupied.contains(&suggestion.to_lowercase()) {
				return NicknameAvailability::Taken {
					source: if directory_taken { "directory" } else { "room" },
					suggestion,
				};
			}
			suggestion = suggested_nick(&suggestion);
		}
		return NicknameAvailability::Unknown;
	}
	if room_known {
		NicknameAvailability::Available
	} else {
		NicknameAvailability::Unknown
	}
}

pub use crate::protocol_data::{MEMBER_REGISTRATION as MEMBER, OFFER_INBOX, REGISTER, REQUEST_DIRECT, VOUCHER};
pub const MAX_EVENTS: usize = 256;
pub const MAX_HELD_DIRECTORIES: usize = 64;
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Claim {
	Named,
	Signaling,
}

/// Signaling-only tab registrations do not consume a workspace nickname.
/// The bounded alternatives preserve the original tab naming contract.
pub const SIGNALING_NAME_ATTEMPTS: usize = 4;
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
	Id,
	Peer,
	Grant,
	Name,
	Voucher,
	Busy,
	Ended,
	NoPending,
	Overflow,
	Claimed,
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Id => "the directory did not name a valid registration ID",
			Self::Peer => "the directory named an invalid peer",
			Self::Grant => "the directory granted a different nickname than the exact request",
			Self::Name => "the directory answered without a name capability",
			Self::Voucher => "the directory answered an invalid name voucher",
			Self::Busy => "finish the pending registration before starting another operation",
			Self::Ended => "the directory registration has ended",
			Self::NoPending => "there is no pending directory registration",
			Self::Overflow => "the registration inbox could not keep up",
			Self::Claimed => "the directory name belongs to an application registration",
		})
	}
}
impl core::error::Error for Error {}
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Id(String);
impl Id {
	pub fn parse(text: &str) -> Result<Self, Error> {
		// The shared UUID grammar rejects before retaining remote text.
		if !super::registration_id_text(text) {
			return Err(Error::Id);
		}
		Ok(Self(text.into()))
	}
	pub fn as_str(&self) -> &str {
		&self.0
	}
	/// A fresh random identity from sixteen bytes the caller drew: a version 4
	/// UUID in the same grammar `parse` accepts.
	pub fn from_entropy(mut bytes: [u8; 16]) -> Self {
		bytes[6] = (bytes[6] & 0x0f) | 0x40;
		bytes[8] = (bytes[8] & 0x3f) | 0x80;
		let digits = lower_hex(&bytes);
		let text = format!(
			"{}-{}-{}-{}-{}",
			&digits[..8],
			&digits[8..12],
			&digits[12..16],
			&digits[16..20],
			&digits[20..],
		);
		debug_assert!(super::registration_id_text(&text));
		Self(text)
	}
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
	MintInboxFor,
	DirectRequested,
	Introducible,
}
#[derive(Debug)]
pub struct Event {
	pub kind: Kind,
	pub peer: Text<32, true>,
	pub registration: Id,
	pub opening: Option<Text<128, true>>,
}
#[derive(Default)]
pub struct Events {
	held: alloc::collections::VecDeque<Event>,
	overflow: bool,
}
impl Events {
	pub fn push(&mut self, event: Event) -> Result<(), Error> {
		if self.overflow || self.held.len() == MAX_EVENTS {
			self.overflow = true;
			self.held = alloc::collections::VecDeque::new();
			return Err(Error::Overflow);
		}
		self.held.push_back(event);
		Ok(())
	}
	pub fn pop(&mut self) -> Result<Option<Event>, Error> {
		if self.overflow {
			Err(Error::Overflow)
		} else {
			Ok(self.held.pop_front())
		}
	}
}
pub enum Notice {
	Registered { nick: Text<32, true>, id: Id },
	Event(Event),
}
pub fn notice<A: ArgumentView>(verb: &str, at: impl Fn(usize) -> Option<A>) -> Result<Option<Notice>, Error> {
	if verb != crate::protocol_data::NOTIFY {
		return Ok(None);
	}
	let Some(tag) = at(0) else { return Ok(None) };
	let kind = match tag.text() {
		Some(crate::protocol_data::REGISTERED) => {
			let nick_value = at(1).ok_or(Error::Peer)?;
			let nick = nick_value.text().ok_or(Error::Peer)?;
			if !crate::room::inbox::valid_nick(nick) {
				return Err(Error::Peer);
			}
			let id = at(2).ok_or(Error::Id)?;
			return Ok(Some(Notice::Registered {
				nick: Text(nick.into()),
				id: Id::parse(id.text().unwrap_or(""))?,
			}));
		}
		Some("mintInboxFor") => Kind::MintInboxFor,
		Some(crate::protocol_data::DIRECT_REQUESTED) => Kind::DirectRequested,
		Some("introducible") => Kind::Introducible,
		_ => return Ok(None),
	};
	let Some(peer) = at(1) else { return Ok(None) };
	let Some(peer) = peer.text().filter(|s| !s.is_empty()) else {
		return Ok(None);
	};
	if !Text::<32, true>::accepts_utf16(peer.encode_utf16()) {
		return Err(Error::Peer);
	}
	let id = at(2).ok_or(Error::Id)?;
	let registration = Id::parse(id.text().unwrap_or(""))?;
	Ok(Some(Notice::Event(Event {
		kind,
		opening: if kind == Kind::DirectRequested {
			None
		} else {
			let opening = at(3).ok_or(Error::Id)?;
			Some(Text::new(opening.text().unwrap_or("").into()).ok_or(Error::Id)?)
		},
		peer: Text(peer.into()),
		registration,
	})))
}
/// One owner retains its previous name until an actual capability reply
/// replaces it. Completion observation is a separate barrier from that commit.
pub struct Custody<C> {
	current: Option<C>,
	pending: bool,
	ended: bool,
}
impl<C> Default for Custody<C> {
	fn default() -> Self {
		Self {
			current: None,
			pending: false,
			ended: false,
		}
	}
}
impl<C> Custody<C> {
	pub fn ended(&self) -> bool {
		self.ended
	}
	pub fn begin(&mut self) -> Result<(), Error> {
		if self.ended {
			return Err(Error::Ended);
		}
		if self.pending {
			return Err(Error::Busy);
		}
		self.pending = true;
		Ok(())
	}
	pub fn replace(&mut self, name: C) -> Result<(), Error> {
		if self.ended {
			return Err(Error::Ended);
		}
		if !self.pending {
			return Err(Error::NoPending);
		}
		self.current = Some(name);
		Ok(())
	}
	pub fn finish(&mut self) -> Result<(), Error> {
		if !self.pending {
			return Err(Error::NoPending);
		}
		self.pending = false;
		Ok(())
	}
	pub fn name(&self) -> Result<Option<&C>, Error> {
		if self.ended {
			return Err(Error::Ended);
		}
		if self.pending {
			return Err(Error::Busy);
		}
		Ok(self.current.as_ref())
	}
	pub fn take(&mut self) -> Result<Option<C>, Error> {
		self.name()?;
		Ok(self.current.take())
	}
	pub fn close(&mut self) {
		self.ended = true;
		self.current = None;
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use alloc::format;

	#[test]
	fn suggestions_increment_truncate_and_recover_from_numeric_overflow() {
		assert_eq!(suggested_nick("alice"), "alice-2");
		assert_eq!(suggested_nick("alice-2"), "alice-3");
		assert_eq!(suggested_nick(&"a".repeat(32)), format!("{}-2", "a".repeat(30)));
		assert_eq!(suggested_nick("alice-18446744073709551615"), "alice-2");
		assert_eq!(suggested_nick(&"😀".repeat(16)), format!("{}-2", "😀".repeat(15)));
	}

	#[test]
	fn availability_distinguishes_own_directory_room_and_unknown_evidence() {
		let directory = ["Alice", "alice-2"];
		let room = ["alice-3"];
		assert_eq!(
			nickname_availability("alice", Some("ALICE"), Some(directory), None::<[&str; 0]>),
			NicknameAvailability::Available
		);
		assert_eq!(
			nickname_availability("Alice", None, Some(directory), Some(room)),
			NicknameAvailability::Taken {
				source: "directory",
				suggestion: "Alice-4".into(),
			}
		);
		assert_eq!(
			nickname_availability("alice-3", None, Some(directory), Some(room)),
			NicknameAvailability::Taken {
				source: "room",
				suggestion: "alice-4".into(),
			}
		);
		assert_eq!(
			nickname_availability("bob", None, Some(directory), None::<[&str; 0]>),
			NicknameAvailability::Unknown
		);
	}
}
