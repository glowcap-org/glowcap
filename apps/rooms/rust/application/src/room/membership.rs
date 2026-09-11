//! One subscription's reply and local admission state. Arrival notification and
//! subscribe reply are independent; both must finish before exposing a member.
use super::{attachment::AttachmentArgument, policy::MembershipKind};

pub const SUBSCRIBE: &str = "subscribe";
pub const LEAVE: &str = "leave";
pub const AWAY: &str = "away";
pub const TYPING: &str = "typing";
pub const SET_TOPIC: &str = "setTopic";
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	Answer,
	Ended,
	NoTopic,
	GoodbyeUnobserved,
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Answer => "the room answered subscribe without one membership capability",
			Self::Ended => "this room membership has ended",
			Self::NoTopic => "this room did not hand over its topic authority",
			Self::GoodbyeUnobserved => "membership retired after the goodbye observation was cancelled",
		})
	}
}
impl core::error::Error for Error {}
pub struct Seat<C> {
	pub reference: C,
	pub kind: MembershipKind,
	pub topic: Option<C>,
}
pub fn read_answer<A: AttachmentArgument>(args: &[A]) -> Result<Seat<A::Capability>, Error> {
	if args.len() != 3 {
		return Err(Error::Answer);
	}
	let reference = args[0].capability().ok_or(Error::Answer)?;
	let kind = args[1].text().and_then(MembershipKind::parse).ok_or(Error::Answer)?;
	let topic = if args[2].is_null() {
		None
	} else {
		Some(args[2].capability().ok_or(Error::Answer)?)
	};
	Ok(Seat {
		reference: reference.clone(),
		kind,
		topic: topic.cloned(),
	})
}
pub struct Membership<C> {
	seat: Option<Seat<C>>,
	arrived: bool,
	ended: bool,
}
impl<C> Default for Membership<C> {
	fn default() -> Self {
		Self::new()
	}
}
impl<C> Membership<C> {
	pub fn new() -> Self {
		Self {
			seat: None,
			arrived: false,
			ended: false,
		}
	}
	pub fn accept(&mut self, seat: Seat<C>) -> Result<(), Error> {
		if self.ended || self.seat.is_some() {
			return Err(Error::Ended);
		}
		self.seat = Some(seat);
		Ok(())
	}
	pub fn arrived(&mut self) {
		if !self.ended {
			self.arrived = true;
		}
	}
	pub fn ready(&self) -> bool {
		self.arrived && self.seat.is_some() && !self.ended
	}
	pub fn ended(&self) -> bool {
		self.ended
	}
	pub fn seat(&self) -> Result<&Seat<C>, Error> {
		self.seat.as_ref().filter(|_| !self.ended).ok_or(Error::Ended)
	}
	/// Retire before any external goodbye. The caller retains just the exact
	/// old seat needed for that courtesy; a replacement can never be addressed.
	pub fn retire(&mut self) -> Option<Seat<C>> {
		self.ended = true;
		self.seat.take()
	}
}

/// Maximum UTF-16 length of a member's away reason across room adapters.
pub const MAX_AWAY: usize = 120;
