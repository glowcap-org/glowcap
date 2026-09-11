//! What a room says and asks: the notices members hear, the capabilities
//! given back, the directory events announced, and the history persisted.
use crate::{
	directory::Event,
	room::{
		message::{ChangeKind, LineId},
		policy::RoomPolicy,
		stewardship::Kind,
	},
	server::history::Persist,
};
use alloc::{format, string::String, vec::Vec};

pub use crate::files::Blob;

/// One thing a member's inbox hears.
#[derive(Clone, Debug, PartialEq)]
pub enum Notice {
	/// A line said, edited, refiled, or withdrawn. The adapter mints one blob
	/// capability per file on the hearing member's own connection.
	Line {
		from: String,
		text: String,
		marker: Option<(ChangeKind, LineId)>,
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

/// A capability the adapter gives back on the connection it lives on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Release<C, R> {
	pub connection: C,
	pub capability: R,
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
	/// The display text a notice carries beside its tag.
	pub fn said(&self) -> String {
		match self {
			Self::Line { text, .. } => text.clone(),
			Self::Roster(names) => super::state::roster_said(names),
			Self::Join { nick, count } => format!("{nick} joined ({count} here)"),
			Self::Leave { nick, count } => format!("{nick} left ({count} here)"),
			Self::Away { nick, why } => {
				if why.is_empty() {
					format!("{nick} is back")
				} else {
					format!("{nick} is away: {why}")
				}
			}
			Self::Topic { text, changed: false } => format!("the topic is: {text}"),
			Self::Topic { text, changed: true } => {
				if text.is_empty() {
					"the topic was taken down".into()
				} else {
					format!("the topic is now: {text}")
				}
			}
			Self::Said(text) | Self::Ended(text) => text.clone(),
			Self::Listed(_) | Self::Typing { .. } | Self::AuthorityChanged { .. } | Self::PolicyChanged(_) => {
				String::new()
			}
		}
	}
}
