//! The turn ledger and the durable cursor, in one atomically replaced file so
//! they never disagree. Every change is written first. A write that left the
//! file unchanged leaves memory as it was, so the same change can be made
//! again. A write whose replacement may or may not have landed leaves memory
//! holding the new document and marks it unsettled. The next change, and
//! [`Ledger::durable`] before any send, write that same document again first,
//! so the file never holds a document memory did not.
//!
//! The cursor is the session's own, and every event after it is either
//! unread or covered by a row here. The bot numbers events itself as it reads
//! them, starting from the cursor's number, so rows are ordered without ever
//! ordering a cursor. A row names its trigger events by their cursors, and a
//! replayed event is recognized by that name. A finished row stays until the
//! cursor's number passes its last event, because until then a restart reads
//! its events again.
use super::{
	classify::{Seq, Trigger},
	error::Error,
	rooms::{Base, ConversationId, Cursor, Kind},
	store::{self, Store},
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

pub const FILE: &str = "turns.json";
/// The largest ledger the bot writes or reads. The bounds below keep the
/// worst case under it, and a test fills every bound to prove that.
pub const MAX_LEDGER_BYTES: usize = 16 * 1024 * 1024;
/// How many times a turn runs the harness before it posts a failure line.
pub const MAX_RUNS: u32 = 2;
/// The most triggers one turn answers. Later ones wait for the next turn.
pub const MAX_TRIGGERS: usize = 8;
/// The most unfinished turns at once: waiting for the harness, running, or
/// sending.
pub const MAX_OPEN: usize = 16;
/// The most rows at once. Triggers become turns in the order they were read,
/// so no trigger waits behind a turn begun after it, and the next cursor move
/// drops every finished row. Until then a finished row holds its place, so at
/// most one finished row stands beside each open one.
pub const MAX_ROWS: usize = 2 * MAX_OPEN;
/// The longest failure note a running turn keeps.
pub const MAX_NOTE_BYTES: usize = 256;

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

/// A running turn's count of spent runs and its progress, as stored.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Started {
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
	/// Sent at `base` by the access of a link this bot replaced, which alone
	/// could keep or release its receipt. Only the line's echo after `after`
	/// settles it, and it is never sent again.
	Handed { base: Base, after: Cursor },
}

/// The trigger events a turn answered, kept so their replay is recognized.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Covered {
	pub events: Vec<Cursor>,
	/// The number of the last of them.
	pub last: Seq,
}

impl Covered {
	fn of(triggers: &[Trigger]) -> Self {
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
		spent: u32,
		note: Option<String>,
		progress: Progress,
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
	fn covers(&self, event: &Cursor) -> bool {
		match self {
			Self::Running { asked, .. } => asked.triggers.iter().any(|trigger| trigger.event == *event),
			Self::Sending { covered, .. } | Self::Done { covered } => covered.events.contains(event),
		}
	}
	fn is_open(&self) -> bool {
		!matches!(self, Self::Done { .. })
	}
	fn conversation(&self) -> Option<&ConversationId> {
		match self {
			Self::Running { asked, .. } => Some(&asked.conversation),
			Self::Sending { conversation, .. } => Some(conversation),
			Self::Done { .. } => None,
		}
	}
}

#[derive(Serialize, Deserialize)]
struct Row {
	id: TurnId,
	#[serde(flatten)]
	phase: Phase,
}

#[derive(Serialize, Deserialize)]
struct Document {
	cursor: Cursor,
	/// The number the first event after the cursor gets.
	cursor_seq: Seq,
	next_turn: TurnId,
	turns: Vec<Row>,
}

#[derive(Clone)]
pub struct Ledger {
	cursor: Cursor,
	cursor_seq: Seq,
	next_turn: TurnId,
	rows: BTreeMap<TurnId, Phase>,
	/// The last write may not have landed. Memory holds what it wrote.
	unsettled: bool,
}

fn missing() -> Error {
	Ledger::invariant("a turn left the ledger while it ran")
}

/// A failure note cut on a character boundary to [`MAX_NOTE_BYTES`].
fn bounded_note(mut note: String) -> String {
	note.truncate(note.floor_char_boundary(MAX_NOTE_BYTES));
	note
}

impl Ledger {
	/// A ledger that breaks one of its own rules, for `reason`.
	pub fn invariant(reason: &str) -> Error {
		Error::state(FILE, reason)
	}

	/// The ledger a previous `serve` left, or none on a first start.
	pub fn load(store: &Store) -> Result<Option<Self>, Error> {
		let Some(document) = store.read_bounded::<Document>(FILE, MAX_LEDGER_BYTES)? else {
			return Ok(None);
		};
		let mut rows = BTreeMap::new();
		for row in document.turns {
			if row.id >= document.next_turn {
				return Err(Error::unreadable(FILE, "a turn's number was never handed out"));
			}
			if rows.insert(row.id, row.phase).is_some() {
				return Err(Error::unreadable(FILE, "two turns share a number"));
			}
		}
		Ok(Some(Self {
			cursor: document.cursor,
			cursor_seq: document.cursor_seq,
			next_turn: document.next_turn,
			rows,
			unsettled: false,
		}))
	}

	/// A first ledger whose cursor is the head of activity, written before the
	/// bot serves, so history from before the bot existed is never answered.
	pub fn start(store: &Store, cursor: Cursor) -> Result<Self, Error> {
		let ledger = Self {
			cursor,
			cursor_seq: Seq(0),
			next_turn: TurnId(0),
			rows: BTreeMap::new(),
			unsettled: false,
		};
		ledger.persist(store)?;
		Ok(ledger)
	}

	fn encode(&self) -> Result<Vec<u8>, Error> {
		let document = Document {
			cursor: self.cursor.clone(),
			cursor_seq: self.cursor_seq,
			next_turn: self.next_turn,
			turns: self
				.rows
				.iter()
				.map(|(id, phase)| Row {
					id: *id,
					phase: phase.clone(),
				})
				.collect(),
		};
		store::encode(FILE, &document, MAX_LEDGER_BYTES)
	}

	fn persist(&self, store: &Store) -> Result<(), Error> {
		store.write_bytes(FILE, &self.encode()?)
	}

	/// Write again the document memory holds, after a write that may not have
	/// landed. Call it before any effect the ledger must be ahead of.
	pub fn durable(&mut self, store: &Store) -> Result<(), Error> {
		if self.unsettled {
			self.persist(store)?;
			self.unsettled = false;
		}
		Ok(())
	}

	/// Make a change on a copy, write the copy, and keep it once it is written
	/// or may have been.
	fn commit<T>(&mut self, store: &Store, change: impl FnOnce(&mut Self) -> Result<T, Error>) -> Result<T, Error> {
		self.durable(store)?;
		let mut next = self.clone();
		let value = change(&mut next)?;
		match next.persist(store) {
			Ok(()) => {
				*self = next;
				Ok(value)
			}
			Err(error @ Error::Unsettled(_)) => {
				*self = next;
				self.unsettled = true;
				Err(error)
			}
			Err(error) => Err(error),
		}
	}

	fn change(
		&mut self,
		store: &Store,
		id: TurnId,
		change: impl FnOnce(&mut Phase) -> Result<(), Error>,
	) -> Result<(), Error> {
		self.commit(store, |next| change(next.rows.get_mut(&id).ok_or_else(missing)?))
	}

	pub fn cursor(&self) -> &Cursor {
		&self.cursor
	}

	pub fn cursor_seq(&self) -> Seq {
		self.cursor_seq
	}

	pub fn phase(&self, id: TurnId) -> Option<&Phase> {
		self.rows.get(&id)
	}

	/// Whether some turn already took this event as a trigger.
	pub fn covers(&self, event: &Cursor) -> bool {
		self.rows.values().any(|phase| phase.covers(event))
	}

	/// The turns that still need work, oldest first.
	pub fn open(&self) -> Vec<TurnId> {
		self.rows
			.iter()
			.filter(|(_, phase)| phase.is_open())
			.map(|(id, _)| *id)
			.collect()
	}

	/// The conversations with a turn that still needs work.
	pub fn open_conversations(&self) -> BTreeSet<ConversationId> {
		self.rows.values().filter_map(Phase::conversation).cloned().collect()
	}

	/// How many turns have finished since the bot directory was first served.
	/// Turn numbers are never reused and the ledger keeps the next one, so
	/// every number below it that is not open has finished, across restarts.
	pub fn finished(&self) -> u64 {
		let open = self.rows.values().filter(|phase| phase.is_open()).count();
		self.next_turn.0.saturating_sub(u64::try_from(open).unwrap_or(u64::MAX))
	}

	/// How many open turns are sending their reply.
	pub fn sending(&self) -> usize {
		self.rows
			.values()
			.filter(|phase| matches!(phase, Phase::Sending { .. }))
			.count()
	}

	/// Whether another turn fits. One that does not waits until an earlier
	/// turn finishes, which never waits on a later trigger.
	pub fn has_room(&self) -> bool {
		self.open().len() < MAX_OPEN && self.rows.len() < MAX_ROWS
	}

	/// How many more triggers turn `id` can take: room up to [`MAX_TRIGGERS`]
	/// while its harness has never started, and none after.
	pub fn room_in(&self, id: TurnId) -> usize {
		match self.rows.get(&id) {
			Some(Phase::Running {
				asked,
				spent: 0,
				note: None,
				progress: Progress::Ready,
			}) => MAX_TRIGGERS.saturating_sub(asked.triggers.len()),
			_ => 0,
		}
	}

	/// Start a turn. The row is durable before the harness starts.
	pub fn begin(&mut self, store: &Store, asked: Asked) -> Result<TurnId, Error> {
		if asked.triggers.is_empty() || asked.triggers.len() > MAX_TRIGGERS {
			return Err(Error::state(FILE, "a turn's triggers are missing or past its bound"));
		}
		if !self.has_room() {
			return Err(Error::state(FILE, "a turn was begun past the ledger's bounds"));
		}
		self.commit(store, |next| {
			let id = next.next_turn;
			next.next_turn = TurnId(id.0.saturating_add(1));
			next.rows.insert(
				id,
				Phase::Running {
					asked,
					spent: 0,
					note: None,
					progress: Progress::Ready,
				},
			);
			Ok(id)
		})
	}

	/// Add triggers read later to a turn whose harness has not started.
	pub fn extend(&mut self, store: &Store, id: TurnId, triggers: Vec<Trigger>) -> Result<(), Error> {
		if triggers.is_empty() || triggers.len() > self.room_in(id) {
			return Err(Error::state(FILE, "triggers were added past a turn's room"));
		}
		self.change(store, id, |phase| match phase {
			Phase::Running { asked, .. } => {
				asked.triggers.extend(triggers);
				Ok(())
			}
			_ => Err(Error::state(FILE, "triggers were added to a turn that is not running")),
		})
	}

	/// Record that a harness run starts, after `spent` runs have ended.
	pub fn start_run(&mut self, store: &Store, id: TurnId, spent_now: u32) -> Result<(), Error> {
		self.change(store, id, |phase| match phase {
			Phase::Running { spent, progress, .. } => {
				*spent = spent_now;
				*progress = Progress::InFlight;
				Ok(())
			}
			_ => Err(Error::state(FILE, "a run started for a turn that is not running")),
		})
	}

	/// Return a turn to what it was before [`Ledger::start_run`], for a run
	/// whose harness never started, so it spends nothing.
	pub fn unstart_run(&mut self, store: &Store, id: TurnId, before: Started) -> Result<(), Error> {
		self.change(store, id, |phase| match phase {
			Phase::Running { spent, progress, .. } => {
				*spent = before.spent;
				*progress = before.progress;
				Ok(())
			}
			_ => Err(Error::state(FILE, "a run was undone for a turn that is not running")),
		})
	}

	/// Record a run that ended without an answer and may be tried again.
	pub fn retry(&mut self, store: &Store, id: TurnId, why: String) -> Result<(), Error> {
		self.change(store, id, |phase| match phase {
			Phase::Running {
				spent, note, progress, ..
			} => {
				*spent = spent.saturating_add(1);
				*note = Some(bounded_note(why));
				*progress = Progress::Ready;
				Ok(())
			}
			_ => Err(Error::state(FILE, "a run ended for a turn that is not running")),
		})
	}

	/// Record a run the bot's own stop cut off. It spends nothing.
	pub fn cut_off(&mut self, store: &Store, id: TurnId) -> Result<(), Error> {
		self.change(store, id, |phase| match phase {
			Phase::Running { progress, .. } => {
				*progress = Progress::CutOff;
				Ok(())
			}
			_ => Err(Error::state(FILE, "a run was cut off for a turn that is not running")),
		})
	}

	/// Fix the reply's lines and their operations before the first is sent.
	pub fn answer(&mut self, store: &Store, id: TurnId, content: Content, parts: Vec<Part>) -> Result<(), Error> {
		if parts.is_empty() {
			return Err(Error::state(FILE, "a reply needs a line"));
		}
		self.change(store, id, |phase| {
			let Phase::Running { asked, .. } = phase else {
				return Err(Error::state(FILE, "a reply was fixed for a turn that is not running"));
			};
			*phase = Phase::Sending {
				conversation: asked.conversation.clone(),
				covered: Covered::of(&asked.triggers),
				content,
				parts,
				sent: 0,
				attempt: Attempt::Unsent,
			};
			Ok(())
		})
	}

	fn change_sending(
		&mut self,
		store: &Store,
		id: TurnId,
		change: impl FnOnce(&mut Vec<Part>, &mut usize, &mut Attempt, &mut Content) -> Result<(), Error>,
	) -> Result<(), Error> {
		self.change(store, id, |phase| match phase {
			Phase::Sending {
				parts,
				sent,
				attempt,
				content,
				..
			} => change(parts, sent, attempt, content),
			_ => Err(Error::state(FILE, "a send was recorded for a turn that is not sending")),
		})
	}

	/// Record that the next line is settled: kept, released, left with a
	/// replaced access, or given up on without being sent again.
	pub fn part_sent(&mut self, store: &Store, id: TurnId) -> Result<(), Error> {
		self.change_sending(store, id, |parts, sent, attempt, _| {
			if *sent >= parts.len() {
				return Err(Error::state(FILE, "a reply has no line left to send"));
			}
			*sent += 1;
			*attempt = Attempt::Unsent;
			Ok(())
		})
	}

	/// Record where the next line's send stands. A base, once recorded for an
	/// operation, never changes, and a line settled without being kept never
	/// goes back to being sent.
	pub fn attempt(&mut self, store: &Store, id: TurnId, next: Attempt) -> Result<(), Error> {
		self.change_sending(store, id, |_, _, attempt, _| {
			let kept = match (&*attempt, &next) {
				(Attempt::Unsent, Attempt::Sent { .. }) => true,
				(
					Attempt::Sent { base, .. },
					Attempt::Sent { base: now, .. }
					| Attempt::Committed { base: now }
					| Attempt::Releasing { base: now }
					| Attempt::Handed { base: now, .. },
				)
				| (Attempt::Committed { base }, Attempt::Committed { base: now } | Attempt::Releasing { base: now })
				| (Attempt::Releasing { base }, Attempt::Releasing { base: now }) => base == now,
				_ => false,
			};
			if !kept {
				return Err(Error::state(
					FILE,
					"a send moved to a base or a stage its operation cannot reach",
				));
			}
			*attempt = next;
			Ok(())
		})
	}

	/// Give the next line a new operation, after the session committed nothing
	/// for the one it was sent under.
	pub fn reissue(&mut self, store: &Store, id: TurnId, operation: String) -> Result<(), Error> {
		self.change_sending(store, id, |parts, sent, attempt, _| {
			if !matches!(attempt, Attempt::Sent { .. }) {
				return Err(Error::state(
					FILE,
					"a line was given a new operation it was never sent under",
				));
			}
			let part = parts.get_mut(*sent).ok_or_else(missing)?;
			part.operation = operation;
			*attempt = Attempt::Unsent;
			Ok(())
		})
	}

	/// Replace the lines not yet sent with one failure line. A line that may
	/// have posted is never replaced.
	pub fn fail_rest(&mut self, store: &Store, id: TurnId, part: Part) -> Result<(), Error> {
		self.change_sending(store, id, |parts, sent, attempt, content| {
			if !matches!(attempt, Attempt::Unsent | Attempt::Sent { .. }) {
				return Err(Error::state(FILE, "a settled line was replaced by a failure line"));
			}
			parts.truncate(*sent);
			parts.push(part);
			*attempt = Attempt::Unsent;
			*content = Content::Failure;
			Ok(())
		})
	}

	pub fn done(&mut self, store: &Store, id: TurnId) -> Result<(), Error> {
		self.change(store, id, |phase| {
			let covered = match phase {
				Phase::Running { asked, .. } => Covered::of(&asked.triggers),
				Phase::Sending { covered, .. } => covered.clone(),
				Phase::Done { .. } => return Ok(()),
			};
			*phase = Phase::Done { covered };
			Ok(())
		})
	}

	/// Move the cursor to `cursor`, whose next event gets number `seq`, and drop
	/// the finished turns it passed. Returns whether the cursor moved.
	pub fn advance(&mut self, store: &Store, cursor: &Cursor, seq: Seq) -> Result<bool, Error> {
		if seq <= self.cursor_seq {
			return Ok(false);
		}
		self.commit(store, |next| {
			next.cursor = cursor.clone();
			next.cursor_seq = seq;
			next.rows.retain(|_, phase| match phase {
				Phase::Done { covered } => covered.last >= seq,
				_ => true,
			});
			Ok(true)
		})
	}
}

#[cfg(test)]
mod tests;
