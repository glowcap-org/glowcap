//! What one ledger row holds: a turn's number, what it answers, how far its
//! harness run got, and where each line of its reply stands. The ledger
//! (`../ledger.rs`) owns the document and every change to it, and these are
//! the values it stores.
use crate::bot::{
	classify::{Seq, Trigger},
	rooms::{Base, ConversationId, Cursor, Kind},
};
use serde::{Deserialize, Serialize};

/// A turn's own number. Numbers are never reused.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct TurnId(pub u64);

/// What a turn answers. Fixed when the turn begins.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Asked {
	pub conversation: ConversationId,
	pub kind: Kind,
	pub triggers: Vec<Trigger>,
}

/// Where a running turn's current harness run stands.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Progress {
	/// No run is in flight.
	Ready,
	/// A run started and has not ended. Found at startup, the bot died during it.
	InFlight,
	/// A run was cut off by the bot stopping. The next prompt says so.
	CutOff,
}

/// A running turn's count of spent runs and where the current one stands, as
/// stored in the turn's row.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Runs {
	pub spent: u32,
	pub progress: Progress,
}

/// What the lines of a sending turn say.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Content {
	Answer,
	/// A short line saying the turn could not be answered.
	Failure,
}

/// One line of a reply, with the operation that sends it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Part {
	pub operation: String,
	pub text: String,
}

/// Where the send of a reply's next line stands.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Attempt {
	/// Not sent under its operation yet.
	Unsent,
	/// Sent, or about to be, at `base`, which is recorded before the send and
	/// used for every later look at the same operation. `after` was the cursor
	/// when the base was recorded, so the line's echo is in activity after it.
	/// `looks` counts the looks that found the send unsettled.
	Sent { base: Base, after: Cursor, looks: u32 },
	/// The session committed it at `base`. Keeping it remains.
	Committed { base: Base },
	/// Settled without being kept: the operation is never sent again, and
	/// its receipt at `base` is still to be released. It is recorded before
	/// the release, so a restart between the two finishes the release.
	Releasing { base: Base },
}

impl Attempt {
	/// Whether the line was sent, or was about to be, so the session may hold
	/// its receipt.
	pub fn is_sent(&self) -> bool {
		!matches!(self, Self::Unsent)
	}

	/// The base a line was sent at, once it was sent.
	pub fn base(&self) -> Option<Base> {
		match *self {
			Self::Unsent => None,
			Self::Sent { base, .. } | Self::Committed { base } | Self::Releasing { base } => Some(base),
		}
	}
}

/// The trigger events a turn answered, kept so their replay is recognized.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Covered {
	pub events: Vec<Cursor>,
	/// The number of the last of them.
	pub last: Seq,
}

impl Covered {
	pub(super) fn of(triggers: &[Trigger]) -> Self {
		Self {
			events: triggers.iter().map(|trigger| trigger.event.clone()).collect(),
			last: triggers.iter().map(|trigger| trigger.seq).max().unwrap_or_default(),
		}
	}
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "phase", rename_all = "lowercase")]
pub enum Phase {
	/// The harness is answering. `spent` runs have ended without an answer,
	/// the last one for `note`.
	Running {
		asked: Asked,
		#[serde(flatten)]
		runs: Runs,
		note: Option<String>,
	},
	/// The reply is fixed and its lines go out in order. `sent` lines are
	/// settled. `attempt` is where the next line's send stands.
	Sending {
		conversation: ConversationId,
		covered: Covered,
		content: Content,
		parts: Vec<Part>,
		sent: usize,
		attempt: Attempt,
	},
	/// Nothing remains but recognizing a replay of the triggers.
	Done { covered: Covered },
}

impl Phase {
	pub(super) fn covers(&self, event: &Cursor) -> bool {
		match self {
			Self::Running { asked, .. } => asked.triggers.iter().any(|trigger| trigger.event == *event),
			Self::Sending { covered, .. } | Self::Done { covered } => covered.events.contains(event),
		}
	}
	/// Whether the harness may still run for the turn, so its verbs may still
	/// act. This is the one definition of what its verbs own.
	pub(super) fn is_running(&self) -> bool {
		matches!(self, Self::Running { .. })
	}
	pub(super) fn is_open(&self) -> bool {
		!matches!(self, Self::Done { .. })
	}
	pub(super) fn conversation(&self) -> Option<&ConversationId> {
		match self {
			Self::Running { asked, .. } => Some(&asked.conversation),
			Self::Sending { conversation, .. } => Some(conversation),
			Self::Done { .. } => None,
		}
	}
}
