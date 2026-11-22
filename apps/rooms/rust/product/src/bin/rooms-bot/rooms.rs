//! The one seam between the bot and a Rooms session. The engine reads typed
//! events after an opaque cursor, sends lines under operation ids, and saves
//! the files a line carries. How a session is reached, and every wire shape
//! behind it, belongs to the implementations of [`Rooms`]: `captp` for a
//! granted session capability, and `files` for the directory stand-in the
//! process tests drive.
//!
//! The bot relies on these facts about every implementation:
//!
//! - A cursor is opaque. The bot never orders, compares, or parses one. It
//!   orders events by a sequence it assigns itself.
//! - Reading from a cursor yields the events after it in the session's order.
//!   An event's own cursor is stable: reading again from an earlier cursor
//!   yields the same event with the same cursor, so the bot recognizes a
//!   replayed event by that cursor alone.
//! - A send names an operation and a base, the revision the bot read and
//!   recorded before it sent. Sending the same operation at the same base
//!   again posts nothing new and answers from the first send's receipt. The
//!   bot never sends an operation at a second base.
//! - A send at a base the workspace has since moved past is refused as
//!   [`Outcome::Conflict`] and installs nothing. The session never admits an
//!   operation at that base again, so a send still on its way cannot post
//!   once a resend at its base was refused.
//! - Receipts are durable across session restarts. A session keeps a bounded
//!   set of them, and it never lets go of a send still running or of a
//!   committed receipt nobody kept, until the access that sent it is revoked.
//!   It may let go of any other, including an unknown one whose line posted. A receipt it no longer holds is
//!   [`Outcome::Absent`], which proves nothing, so the bot asks
//!   [`Rooms::echoed`] whether the line reached activity before it decides
//!   anything.
//! - Every receipt the bot stops caring about is kept or released, because
//!   the receipts it leaves behind would fill the session's places and stop
//!   every command, the owner's included.
//! - A send that has not settled comes back [`Outcome::Pending`] after the
//!   session's own wait (15 seconds for the CapTP view). The bot also gives
//!   each call [`SEND_DEADLINE`] and observes a call still open then.
//! - A committed line is kept with [`Rooms::keep`], so the session holds its
//!   authority and releases its receipt. Keeping a kept line succeeds.
//! - Dropping a future loses nothing. A read that is dropped is asked again
//!   from the same cursor.
use serde::{Deserialize, Serialize};
use std::{fmt, future::Future, path::Path, time::Duration};

pub mod captp;
#[cfg(feature = "test-support")]
pub mod files;

/// How long the bot waits for one send or observe call before it treats the
/// line as unsettled and tries the same operation again.
pub const SEND_DEADLINE: Duration = Duration::from_secs(30);
/// How long the bot waits to save one attachment.
pub const FETCH_DEADLINE: Duration = Duration::from_secs(120);
/// How long the bot waits for one read of events, including the session's
/// own long poll.
pub const READ_DEADLINE: Duration = Duration::from_secs(120);

/// A position in the session's event stream, as the session wrote it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct Cursor(String);

impl Cursor {
	/// The longest cursor the bot keeps. The bot's state files are bounded by it.
	pub const MAX_BYTES: usize = 128;

	/// A cursor the session wrote. A longer one is refused.
	pub fn new(text: impl Into<String>) -> Option<Self> {
		let text = text.into();
		(text.len() <= Self::MAX_BYTES).then_some(Self(text))
	}

	/// The cursor before every event, which asks for the initial backlog.
	pub fn start() -> Self {
		Self(String::new())
	}

	pub fn as_str(&self) -> &str {
		&self.0
	}
}

impl TryFrom<String> for Cursor {
	type Error = String;
	fn try_from(text: String) -> Result<Self, String> {
		Self::new(text).ok_or_else(|| format!("a cursor is longer than {} bytes", Self::MAX_BYTES))
	}
}

impl From<Cursor> for String {
	fn from(cursor: Cursor) -> Self {
		cursor.0
	}
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ConversationId(String);

impl ConversationId {
	pub fn new(id: impl Into<String>) -> Self {
		Self(id.into())
	}
	pub fn as_str(&self) -> &str {
		&self.0
	}
}
impl fmt::Display for ConversationId {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		self.0.fmt(f)
	}
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
	Room,
	Direct,
	/// A kind of conversation this bot does not answer in.
	Other,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Sender {
	/// This session's own member.
	Own,
	/// The room itself, for notices it posts.
	System,
	/// A member a room line names by nickname.
	Member(String),
	/// The other person in a direct conversation, with their nickname in the
	/// conversation's directory when the workspace names it. A direct line
	/// does not name its sender.
	Peer(Option<String>),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Change {
	Said,
	/// An edit, a move, or a withdrawal of an earlier line.
	Revised,
}

pub use rooms_application::room::mentions::Mentions;
pub use rooms_services::session::attached::Attachment;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Line {
	/// The line's id in its conversation.
	pub id: String,
	pub sender: Sender,
	pub change: Change,
	pub text: String,
	pub files: Vec<Attachment>,
	/// Who a room line addresses. `member` is false on every direct line,
	/// because a direct line always addresses the bot. A room-wide mention
	/// sets `room` and is not a mention of this member.
	pub mentions: Mentions,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Body {
	Line(Line),
	/// Presence, typing, membership, and every other notice.
	Other,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Incoming {
	/// The position just after this event. Reading from it yields only later
	/// events, and it names this event when the event is read again.
	pub cursor: Cursor,
	pub conversation: ConversationId,
	pub kind: Kind,
	pub body: Body,
}

/// The events after a cursor. `cursor` is where to read next. `gap` says the
/// session no longer held some events before it and resumed past them.
/// `unavailable` says some events in this range could not be presented.
/// `unreadable` counts events the read skipped because their rows did not
/// decode, so a damaged row is passed by its cursor rather than read forever.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Batch {
	pub events: Vec<Incoming>,
	pub cursor: Cursor,
	pub gap: bool,
	pub unavailable: bool,
	pub unreadable: usize,
}

/// The session revision a send is made at. The bot records it before the
/// send and uses it for every later look at the same operation.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Base(pub u64);

/// One line to post.
#[derive(Clone, Copy, Debug)]
pub struct Outgoing<'a> {
	pub conversation: &'a ConversationId,
	pub text: &'a str,
	/// Names this send. See the module notes for what repeating it means.
	pub operation: &'a str,
}

/// How a send or an observation settled.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
	/// The session holds the line, which may still need keeping.
	Committed,
	/// The send is still running in the session.
	Pending,
	/// The session's receipt says it cannot tell whether the line posted,
	/// because the work that would settle it ended.
	Unknown,
	/// The session holds no receipt for the operation: it never received the
	/// send, or it let the settled receipt go.
	Absent,
	/// Nothing was committed. A new operation may send the line again.
	Conflict,
}

/// Whether a line reached activity, read from the activity after a cursor.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Echo {
	/// An event of this conversation names the operation, so the line posted.
	Found,
	/// Activity after the cursor holds no such event, and nothing was lost
	/// from it.
	NotFound,
	/// The session restarted after the cursor, so activity cannot tell
	/// whether the line posted.
	Restarted,
	/// Activity lost events after the cursor, could not show some, or ran
	/// past the read bound, so its absence proves nothing.
	Unknowable,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RoomsErrorKind {
	/// The session refused this request. Repeating it unchanged will not help.
	Refused,
	/// The bot's access is paused. It resumes when its grantor resumes it.
	Paused,
	/// The bot's access is revoked. Only a new grant restores it.
	Revoked,
	/// The session cannot be reached, did not answer usefully, or asked for
	/// the same request again soon. The request is tried again with backoff,
	/// and never sooner than a wait the session advised.
	Unreachable,
	/// A send's outcome is unknown. Observe the same operation.
	Uncertain,
	/// The file to save is already there.
	Exists,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RoomsError {
	pub kind: RoomsErrorKind,
	pub message: String,
	/// How long the session asked the bot to wait before it tries the same
	/// request again, when it refused it for pacing.
	pub retry_after: Option<Duration>,
}
impl RoomsError {
	pub fn new(kind: RoomsErrorKind, message: impl ToString) -> Self {
		Self {
			kind,
			message: message.to_string(),
			retry_after: None,
		}
	}
}
impl fmt::Display for RoomsError {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		self.message.fmt(f)
	}
}
impl std::error::Error for RoomsError {}

/// A session as the bot uses it. Methods take `&self` so a long read and a
/// send can be in flight together on one task.
pub trait Rooms {
	/// The events after `after`. With `wait`, the session may hold the read
	/// until an event arrives, and an empty batch means it timed out. Without
	/// it, an empty batch means `after` is the head of activity.
	fn events(&self, after: &Cursor, wait: bool) -> impl Future<Output = Result<Batch, RoomsError>>;
	/// The session's revision now, the base of a new send.
	fn base(&self) -> impl Future<Output = Result<Base, RoomsError>>;
	/// Post one line under its operation at `base`, without keeping it.
	fn send(&self, line: &Outgoing<'_>, base: Base) -> impl Future<Output = Result<Outcome, RoomsError>>;
	/// Look again at a send of the same line, operation, and base without
	/// sending it again.
	fn observe(&self, line: &Outgoing<'_>, base: Base) -> impl Future<Output = Result<Outcome, RoomsError>>;
	/// Take the authority of a committed line, so the session releases its
	/// receipt. A line already kept, or whose receipt is gone, succeeds.
	fn keep(&self, line: &Outgoing<'_>, base: Base) -> impl Future<Output = Result<(), RoomsError>>;
	/// Give up the receipt of a send the bot will not keep, without sending
	/// anything. A receipt already gone succeeds.
	fn release(&self, line: &Outgoing<'_>, base: Base) -> impl Future<Output = Result<(), RoomsError>>;
	/// Show the bot as typing in `conversation`, or stop. Readers clear a
	/// notice that is not said again within a few seconds.
	fn typing(&self, conversation: &ConversationId, on: bool) -> impl Future<Output = Result<(), RoomsError>>;
	/// Whether activity after `after` shows the line posted.
	fn echoed(&self, line: &Outgoing<'_>, after: &Cursor) -> impl Future<Output = Result<Echo, RoomsError>>;
	/// Save `attachment` as the new file `destination`, whose parent exists.
	/// An existing destination is refused as [`RoomsErrorKind::Exists`], and a
	/// failed save leaves nothing at the destination. Returns the bytes saved.
	fn fetch(&self, attachment: &Attachment, destination: &Path) -> impl Future<Output = Result<u64, RoomsError>>;
}
