//! Rooms signaling messages and exchange milestones, independent of WebRTC I/O.
use crate::room::ArgumentView;
use alloc::{collections::VecDeque, rc::Rc};
pub mod exchange;
pub use exchange::Exchange;

pub const MAX_EXCHANGES: usize = 64;
pub const MAX_EVENTS: usize = 64;
pub const MAX_ID: usize = 128;
pub const MAX_DESCRIPTION: usize = 16_384;
pub const MAX_CANDIDATE: usize = 4096;
pub const TIMEOUT_MS: u64 = 30_000;
pub use crate::protocol_data::{
	OFFER_SIGNALING as OFFER_INBOX, SIGNAL_ANSWER as ANSWER, SIGNAL_CANDIDATE as CANDIDATE, SIGNAL_DONE as DONE,
	SIGNAL_OFFER as OFFER,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
	Text,
	Reply,
	Inbox,
	Duplicate,
	Full,
	Overflow,
	NotStarted,
	Ended,
	Rejected(Description),
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		match self {
			Self::Rejected(reason) => write!(f, "rooms: {}", reason.as_str()),
			other => f.write_str(match other {
				Self::Text => "signaling text is empty or exceeds its byte limit",
				Self::Reply => "invalid signaling reply",
				Self::Inbox => "invalid relayed signaling message",
				Self::Duplicate => "a signaling exchange for this designator is already active",
				Self::Full => "too many signaling exchanges or observations are active",
				Self::Overflow => "the signaling inbox could not keep up",
				Self::NotStarted => "the signaling offer has not started",
				Self::Ended => "the signaling exchange has ended",
				Self::Rejected(_) => unreachable!(),
			}),
		}
	}
}
impl core::error::Error for Error {}
/// Wire text is UTF-8. Check its byte envelope before one immutable allocation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Text<const N: usize>(Rc<str>);
impl<const N: usize> Text<N> {
	pub fn parse(text: &str) -> Result<Self, Error> {
		if text.is_empty() || text.len() > N {
			return Err(Error::Text);
		}
		Ok(Self(text.into()))
	}
	pub fn as_str(&self) -> &str {
		&self.0
	}
}
pub type Id = Text<MAX_ID>;
pub type Description = Text<MAX_DESCRIPTION>;
pub type Candidate = Text<MAX_CANDIDATE>;
#[derive(Debug)]
pub enum Reply {
	Accepted(Id),
	Answer(Description),
	Candidate(Candidate),
	Rejected(Description),
}
pub fn reply<A: ArgumentView>(verb: &str, len: usize, at: impl Fn(usize) -> Option<A>) -> Result<Reply, Error> {
	if len != 1 {
		return Err(Error::Reply);
	}
	let arg = at(0).ok_or(Error::Reply)?;
	let text = arg.text().ok_or(Error::Reply)?;
	match verb {
		crate::protocol_data::SIG_ACCEPTED => Ok(Reply::Accepted(Id::parse(text)?)),
		crate::protocol_data::SIG_ANSWER => Ok(Reply::Answer(Description::parse(text)?)),
		crate::protocol_data::SIG_CANDIDATE => Ok(Reply::Candidate(Candidate::parse(text)?)),
		crate::protocol_data::SIG_REJECT => Ok(Reply::Rejected(Description::parse(text)?)),
		_ => Err(Error::Reply),
	}
}
#[derive(Debug)]
pub enum Incoming {
	Offer { id: Id, description: Description },
	Candidate { id: Id, candidate: Candidate },
}
pub fn incoming<A: ArgumentView>(verb: &str, len: usize, at: impl Fn(usize) -> Option<A>) -> Result<Incoming, Error> {
	if len != 2 {
		return Err(Error::Inbox);
	}
	let (id, payload) = (at(0).ok_or(Error::Inbox)?, at(1).ok_or(Error::Inbox)?);
	let id = Id::parse(id.text().ok_or(Error::Inbox)?)?;
	let payload = payload.text().ok_or(Error::Inbox)?;
	match verb {
		crate::protocol_data::SIG_OFFER => Ok(Incoming::Offer {
			id,
			description: Description::parse(payload)?,
		}),
		crate::protocol_data::SIG_CANDIDATE => Ok(Incoming::Candidate {
			id,
			candidate: Candidate::parse(payload)?,
		}),
		_ => Err(Error::Inbox),
	}
}
/// Count bounds imply byte bounds because every admitted event is typed first.
pub struct Queue<T> {
	held: VecDeque<T>,
	overflow: bool,
}
impl<T> Default for Queue<T> {
	fn default() -> Self {
		Self {
			held: VecDeque::new(),
			overflow: false,
		}
	}
}
impl<T> Queue<T> {
	pub fn push(&mut self, value: T) -> Result<(), Error> {
		if self.overflow || self.held.len() == MAX_EVENTS {
			self.held = VecDeque::new();
			self.overflow = true;
			return Err(Error::Overflow);
		}
		self.held.push_back(value);
		Ok(())
	}
	pub fn pop(&mut self) -> Result<Option<T>, Error> {
		if self.overflow {
			return Err(Error::Overflow);
		}
		let value = self.held.pop_front();
		if self.held.is_empty() {
			self.held = VecDeque::new();
		}
		Ok(value)
	}
}
