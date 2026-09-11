//! Room membership callbacks above CapTP. Only admitted attachments retain
//! capabilities; the binding retains custody of every original argument.
use super::{
	attachment::{self, Attachment, AttachmentArgument},
	line::MAX_LINE_BYTES,
	message::LineMarker,
	policy::RoomPolicy,
	stewardship::Kind,
	ArgumentView,
};
use alloc::{string::String, vec::Vec};
pub mod metadata;
pub mod queue;
use metadata::{Facts, Presence};

pub const NOTIFY: &str = "notify";
/// The sender name of a line the room itself says: an announcement, never a
/// member's message, and drawn as a system line.
pub const ROOM: &str = "room";
pub const ENDED: &str = "membershipEnded";
pub const AUTHORITY_CHANGED: &str = "roomAuthorityChanged";
pub const POLICY_CHANGED: &str = "roomPolicyChanged";
pub const MAX_NICK: usize = 32;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
	Method,
	Ended,
	Authority,
	Policy,
	Typing,
	Line,
}
impl core::fmt::Display for Refusal {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Method => "a room inbox accepts only notify",
			Self::Ended => "membership-ended notify takes one reason",
			Self::Authority => "room-authority-changed notify takes an authority kind, identity, and claimability",
			Self::Policy => "room-policy notify takes three policy modes",
			Self::Typing => "typing notify takes a valid member name and one boolean",
			Self::Line => "a room line needs a valid sender and text of at most 8192 bytes",
		})
	}
}
impl core::error::Error for Refusal {}
pub const ROOM_MENTIONS: &[&str] = &["here", "room", "channel", "everyone", "all"];
pub fn addresses_everyone(name: &str) -> bool {
	ROOM_MENTIONS.iter().any(|reserved| name.eq_ignore_ascii_case(reserved))
}
pub fn valid_nick(nick: &str) -> bool {
	nick_refusal(nick).is_none()
}

/// Why Rooms will not answer to `nick`, or `None` when it will. A room grants
/// a name, the directory registers one, and a member offers an inbox to one;
/// all three hand out the same thing, so one answer serves all three. The
/// room speaks under "room", drawn as its own voice, and the rest of the
/// room-wide vocabulary addresses everyone at once; a member wearing one could
/// never be addressed apart from the room.
pub fn nick_refusal(nick: &str) -> Option<alloc::string::String> {
	use alloc::format;
	if nick.is_empty() {
		return Some("a name may not be empty".into());
	}
	if !metadata::bounded(nick, MAX_NICK) {
		return Some(format!("a name may be at most {MAX_NICK} characters"));
	}
	if nick.eq_ignore_ascii_case("room") {
		return Some("the name \"room\" is the room's own voice".into());
	}
	if addresses_everyone(nick) {
		return Some(format!("the name \"{nick}\" addresses everyone in a room"));
	}
	// A granted name flows unescaped into every reader's display; a control
	// character is an escape injected there, and a direction override is one
	// name worn to look like another.
	if nick.chars().any(|c| {
		matches!(c,
			'\u{0}'..='\u{1f}' | '\u{7f}'..='\u{9f}' | '\u{200e}' | '\u{200f}' |
			'\u{2028}'..='\u{202e}' | '\u{2066}'..='\u{2069}'
		)
	}) {
		return Some("a name may not carry control or direction characters".into());
	}
	None
}
#[derive(Debug)]
pub struct Message<T, C> {
	pub from: T,
	pub text: T,
	pub presence: Option<Presence<T>>,
	pub facts: Option<Facts<T>>,
	pub marker: Option<LineMarker>,
	pub attachments: Vec<Attachment<C>>,
}
impl<T, C> Message<T, C> {
	pub fn map<U>(self, mut f: impl FnMut(T) -> U) -> Message<U, C> {
		Message {
			from: f(self.from),
			text: f(self.text),
			presence: self.presence.map(|p| p.map(&mut f)),
			facts: self.facts.map(|p| p.map(f)),
			marker: self.marker,
			attachments: self.attachments,
		}
	}
	pub fn arrived(&self) -> bool {
		self.facts.as_ref().is_some_and(|f| f.listed.is_some())
			|| matches!(self.presence, Some(Presence::Roster { .. }))
	}
}
impl<C> Message<&str, C> {
	pub fn into_owned(self) -> Message<String, C> {
		self.map(String::from)
	}
}
pub enum Notice<'a, C> {
	Ended(&'a str),
	Authority {
		kind: Kind,
		token: &'a str,
		claimable: bool,
	},
	Policy(RoomPolicy),
	Typing {
		name: &'a str,
		on: bool,
	},
	Occupancy {
		listed: bool,
		claimable: Option<bool>,
	},
	Line(Message<&'a str, C>),
}
pub fn read<'a, A: AttachmentArgument>(verb: &str, args: &'a [A]) -> Result<Notice<'a, A::Capability>, Refusal> {
	if verb != NOTIFY {
		return Err(Refusal::Method);
	}
	let text = |at: usize| args.get(at).and_then(ArgumentView::text);
	let boolean = |at: usize| args.get(at).and_then(ArgumentView::boolean);
	let prefix = || text(0) == Some("room") && text(1) == Some("");
	match text(2) {
		Some(ENDED) => {
			if args.len() != 3 || text(0) != Some("room") {
				return Err(Refusal::Ended);
			}
			Ok(Notice::Ended(text(1).filter(|s| !s.is_empty()).ok_or(Refusal::Ended)?))
		}
		Some(AUTHORITY_CHANGED) => {
			if args.len() != 6 || !prefix() {
				return Err(Refusal::Authority);
			}
			let kind = match text(3) {
				Some("room") => Kind::Room,
				Some("steward") => Kind::Steward,
				Some("manager") => Kind::Manager,
				_ => return Err(Refusal::Authority),
			};
			Ok(Notice::Authority {
				kind,
				token: text(4).filter(|s| !s.is_empty()).ok_or(Refusal::Authority)?,
				claimable: boolean(5).ok_or(Refusal::Authority)?,
			})
		}
		Some(POLICY_CHANGED) => {
			if args.len() != 6 || !prefix() {
				return Err(Refusal::Policy);
			}
			let modes = [text(3), text(4), text(5)];
			let [Some(a), Some(b), Some(c)] = modes else {
				return Err(Refusal::Policy);
			};
			Ok(Notice::Policy(RoomPolicy::parse(&[a, b, c]).ok_or(Refusal::Policy)?))
		}
		Some("typing") => {
			if args.len() != 5 || !prefix() {
				return Err(Refusal::Typing);
			}
			Ok(Notice::Typing {
				name: text(3).filter(|s| valid_nick(s)).ok_or(Refusal::Typing)?,
				on: boolean(4).ok_or(Refusal::Typing)?,
			})
		}
		_ => {
			let from = text(0).filter(|s| *s == ROOM || valid_nick(s)).ok_or(Refusal::Line)?;
			let text = text(1).filter(|s| s.len() <= MAX_LINE_BYTES).ok_or(Refusal::Line)?;
			let facts = metadata::facts(args);
			let presence = metadata::presence(args);
			if text.is_empty() && presence.is_none() {
				if let Some(listed) = facts.as_ref().and_then(|f| f.listed) {
					return Ok(Notice::Occupancy {
						listed,
						claimable: boolean(3),
					});
				}
			}
			let marker = LineMarker::read(args);
			let attachments = attachment::read_prefix(args, if marker.is_some() { 4 } else { 2 });
			Ok(Notice::Line(Message {
				from,
				text,
				presence,
				facts,
				marker,
				attachments,
			}))
		}
	}
}
