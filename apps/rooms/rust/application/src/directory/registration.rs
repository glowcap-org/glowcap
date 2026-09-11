//! Registered-name custody is distinct from its notification acknowledgement.
use crate::{fields::Text, room::ArgumentView};
use alloc::string::String;

pub const REGISTER: &str = "register";
pub const MEMBER: &str = "memberRegistration";
pub const REQUEST_DIRECT: &str = "requestDirect";
pub const OFFER_INBOX: &str = "offerInbox";
pub const VOUCHER: &str = "voucher";
pub const ACK_MS: u64 = 10_000;
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
pub fn signaling_name(designator: &str, attempt: usize) -> Option<String> {
	if attempt >= SIGNALING_NAME_ATTEMPTS {
		return None;
	}
	let token: String = designator
		.chars()
		.filter(char::is_ascii_alphanumeric)
		.take(12)
		.collect();
	let base = if token.is_empty() {
		String::from("sattach")
	} else {
		alloc::format!("s{token}")
	};
	Some(if attempt == 0 {
		base
	} else {
		alloc::format!("{base}-{}", attempt + 1)
	})
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
	Id,
	Peer,
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
		let mut text = String::with_capacity(36);
		for (i, byte) in bytes.iter().enumerate() {
			if matches!(i, 4 | 6 | 8 | 10) {
				text.push('-');
			}
			use core::fmt::Write;
			write!(text, "{byte:02x}").expect("a String accepts writes");
		}
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
	Registered(Id),
	Event(Event),
}
pub fn notice<A: ArgumentView>(verb: &str, at: impl Fn(usize) -> Option<A>) -> Result<Option<Notice>, Error> {
	if verb != "notify" {
		return Ok(None);
	}
	let Some(tag) = at(0) else { return Ok(None) };
	let kind = match tag.text() {
		Some("registered") => {
			let id = at(2).ok_or(Error::Id)?;
			return Ok(Some(Notice::Registered(Id::parse(id.text().unwrap_or(""))?)));
		}
		Some("mintInboxFor") => Kind::MintInboxFor,
		Some("directRequested") => Kind::DirectRequested,
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
