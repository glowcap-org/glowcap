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
/// What a directory tells an offerer before the reason its target declined.
pub const DECLINED: &str = "the member declined the offer: ";
/// The longest reason a decline carries, so the offerer's `reject` still
/// fits a description.
pub const MAX_REASON: usize = MAX_DESCRIPTION - DECLINED.len();
pub use crate::protocol_data::{
	OFFER_SIGNALING as OFFER_INBOX, SIGNAL_ANSWER as ANSWER, SIGNAL_CANDIDATE as CANDIDATE, SIGNAL_CHECK as CHECK,
	SIGNAL_DECLINE as DECLINE, SIGNAL_DONE as DONE, SIGNAL_OFFER as OFFER,
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
pub type Reason = Text<MAX_REASON>;
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
	/// `from` is the Host key the offering member registered, the one the
	/// directory routes its signaling by, so an answerer can require it of the
	/// channel. It is `None` when the member's locator names no Host key.
	Offer {
		id: Id,
		description: Description,
		from: Option<Id>,
	},
	Candidate {
		id: Id,
		candidate: Candidate,
	},
}
pub fn incoming<A: ArgumentView>(verb: &str, len: usize, at: impl Fn(usize) -> Option<A>) -> Result<Incoming, Error> {
	let text = |i: usize| at(i).ok_or(Error::Inbox);
	match (verb, len) {
		(crate::protocol_data::SIG_OFFER, 2 | 3) => Ok(Incoming::Offer {
			id: parsed(text(0)?)?,
			description: parsed(text(1)?)?,
			from: if len == 3 { Some(parsed(text(2)?)?) } else { None },
		}),
		(crate::protocol_data::SIG_CANDIDATE, 2) => Ok(Incoming::Candidate {
			id: parsed(text(0)?)?,
			candidate: parsed(text(1)?)?,
		}),
		_ => Err(Error::Inbox),
	}
}
fn parsed<A: ArgumentView, const N: usize>(arg: A) -> Result<Text<N>, Error> {
	Text::parse(arg.text().ok_or(Error::Inbox)?)
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
