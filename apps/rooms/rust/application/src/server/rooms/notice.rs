//! What a room says and asks: the notices members hear, the capabilities
//! given back, the directory events announced, and the history persisted.
use crate::{
	directory::Event,
	room::{
		carries::Carries,
		message::{ChangeKind, LineId},
		policy::RoomPolicy,
		stewardship::Kind,
	},
	server::{
		Release,
		history::{KeptLine, Persist},
	},
};
use alloc::{borrow::Cow, format, string::String, sync::Arc, vec::Vec};

pub use crate::files::Blob;

/// One thing a member's inbox hears.
#[derive(Clone, Debug, PartialEq)]
pub enum Notice {
	/// Release retained text even when its caller stopped awaiting the answer.
	ReceiptRejected(u64),
	/// A line said, edited, refiled, or withdrawn. The body is the row the
	/// room keeps for the line, shared rather than copied to each member;
	/// the adapter mints one blob capability per file on the hearing
	/// member's own connection.
	Line {
		line: Arc<KeptLine>,
		marker: Option<(ChangeKind, LineId)>,
		files: Vec<Blob>,
	},
	/// A requested replacement for exactly one subscriber's full post.
	Receipt {
		request: u64,
		line: Arc<KeptLine>,
		id: LineId,
		normalized: bool,
		files: Vec<Blob>,
	},
	/// Who is present, said to the one reader who just arrived.
	Roster(Vec<String>),
	Join {
		nick: String,
		count: usize,
	},
	Leave {
		nick: String,
		count: usize,
	},
	Away {
		nick: String,
		why: String,
	},
	/// What the room is about: told to an arrival, and announced on change.
	Topic {
		text: String,
		changed: bool,
	},
	Listed(bool),
	/// What this room carries, told to an arrival before it is seated.
	Carries(Carries),
	Typing {
		nick: String,
		on: bool,
	},
	/// The room's own line before a departure it caused.
	Said(String),
	Ended(String),
	AuthorityChanged {
		kind: Kind,
		token: String,
	},
	PolicyChanged(RoomPolicy),
}

impl PartialEq for Blob {
	fn eq(&self, other: &Self) -> bool {
		self.description() == other.description()
	}
}

/// A notice for one member's inbox.
#[derive(Clone, Debug, PartialEq)]
pub struct Tell<C, R> {
	pub connection: C,
	pub inbox: R,
	pub notice: Notice,
}

/// A line mutation may change one retained tail. Its distinct result requires
/// the adapter to arrange persistence separately from ordinary room notices.
#[derive(Debug, PartialEq)]
pub struct Mutation<C, R> {
	pub effects: Effects<C, R>,
	pub persist: Option<Persist>,
}
impl<C, R> Default for Mutation<C, R> {
	fn default() -> Self {
		Self {
			effects: Effects::default(),
			persist: None,
		}
	}
}

/// Everything one verb asks the adapter to do, in the order to do it.
#[derive(Debug, PartialEq)]
pub struct Effects<C, R> {
	pub releases: Vec<Release<C, R>>,
	pub tells: Vec<Tell<C, R>>,
	/// Directory events every watcher hears, in order.
	pub events: Vec<Event>,
	/// Connections whose room presence changed: a member seated, moved, or
	/// gone, or a room taken out from under its members. The adapter states
	/// each one's presence for whoever watches the live trace.
	pub presence: Vec<C>,
}
impl<C, R> Default for Effects<C, R> {
	fn default() -> Self {
		Self {
			releases: Vec::new(),
			tells: Vec::new(),
			events: Vec::new(),
			presence: Vec::new(),
		}
	}
}
impl<C: Copy, R: Clone> Effects<C, R> {
	pub(super) fn release(&mut self, connection: C, capability: R) {
		self.releases.push(Release { connection, capability });
	}
	pub(super) fn tell(&mut self, connection: C, inbox: R, notice: Notice) {
		self.tells.push(Tell {
			connection,
			inbox,
			notice,
		});
	}
	pub(super) fn extend(&mut self, other: Self) {
		self.releases.extend(other.releases);
		self.tells.extend(other.tells);
		self.events.extend(other.events);
		self.presence.extend(other.presence);
	}
}

impl Notice {
	/// The display text a notice carries beside its tag: borrowed where the
	/// notice already holds the sentence, composed where it does not.
	pub fn said(&self) -> Cow<'_, str> {
		match self {
			Self::Line { line, .. } | Self::Receipt { line, .. } => Cow::Borrowed(&line.text),
			Self::Roster(names) => super::state::roster_said(names).into(),
			Self::Join { nick, count } => format!("{nick} joined ({count} here)").into(),
			Self::Leave { nick, count } => format!("{nick} left ({count} here)").into(),
			Self::Away { nick, why } => {
				if why.is_empty() {
					format!("{nick} is back").into()
				} else {
					format!("{nick} is away: {why}").into()
				}
			}
			Self::Topic { text, changed: false } => format!("the topic is: {text}").into(),
			Self::Topic { text, changed: true } => {
				if text.is_empty() {
					Cow::Borrowed("the topic was taken down")
				} else {
					format!("the topic is now: {text}").into()
				}
			}
			Self::Said(text) | Self::Ended(text) => Cow::Borrowed(text),
			Self::ReceiptRejected(_)
			| Self::Listed(_)
			| Self::Carries(_)
			| Self::Typing { .. }
			| Self::AuthorityChanged { .. }
			| Self::PolicyChanged(_) => Cow::Borrowed(""),
		}
	}
}
