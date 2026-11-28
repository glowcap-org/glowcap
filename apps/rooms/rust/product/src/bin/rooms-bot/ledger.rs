//! The turn ledger and the durable cursor, in one atomically replaced file so
//! they never disagree. Every change is written first. A write that left the
//! file unchanged leaves memory as it was, so the same change can be made
//! again. A write whose replacement may or may not have landed leaves memory
//! holding the new document, marks it unsettled, and answers the change as
//! made, so the caller holds what memory holds and never makes the change a
//! second time. The next change, and [`Ledger::durable`] before any effect the
//! ledger must be ahead of (a harness run, a send), write that same document
//! again first, so the file never holds a document memory did not and a write
//! that keeps failing stops the effect.
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
	rooms::{ConversationId, Cursor},
	store::{self, Store},
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

mod admission;
pub use admission::Scheduled;
mod phase;
mod replaced;
pub use phase::{Asked, Attempt, Content, Covered, Part, Phase, Progress, Runs, TurnId};
pub use replaced::{MAX_REPLACED, Replaced, Unlisted};

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
/// The most rows at once. Every held trigger is older than every unheld one
/// (`engine/lanes.rs`), so the cursor, which stays before the oldest unheld
/// trigger, has passed every finished row once it is updated, and each update
/// drops them all. Until then a finished row holds its place, so at most one
/// finished row stands beside each open one.
pub const MAX_ROWS: usize = 2 * MAX_OPEN;
/// The longest failure note a running turn keeps.
pub const MAX_NOTE_BYTES: usize = 256;

#[derive(Serialize, Deserialize)]
struct Row {
	id: TurnId,
	#[serde(flatten)]
	phase: Phase,
}

#[derive(Serialize, Deserialize)]
struct Document {
	#[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
	scheduled: BTreeMap<TurnId, admission::Occurrence>,
	#[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
	private: BTreeMap<TurnId, crate::bot::direct_context::Speech>,
	cursor: Cursor,
	/// The number the first event after the cursor gets.
	cursor_seq: Seq,
	next_turn: TurnId,
	#[serde(default)]
	notices: u64,
	turns: Vec<Row>,
	/// The lines this access finished by their echo, which another access
	/// holds the receipt of.
	replaced: Vec<Replaced>,
	/// The operations of lines whose receipts the session would not take
	/// back and which still held a place when it refused.
	#[serde(default)]
	left: Vec<String>,
	/// The operations of the agent's actions an access this one replaced
	/// could not settle before the replacement.
	#[serde(default)]
	replaced_actions: Vec<String>,
	/// Why the old access of the last replacement could not list the
	/// agent's actions it held.
	#[serde(default)]
	unlisted: Option<Unlisted>,
}

#[derive(Clone)]
pub struct Ledger {
	scheduled: BTreeMap<TurnId, admission::Occurrence>,
	private: BTreeMap<TurnId, crate::bot::direct_context::Speech>,
	cursor: Cursor,
	cursor_seq: Seq,
	next_turn: TurnId,
	notices: u64,
	rows: BTreeMap<TurnId, Phase>,
	replaced: Vec<Replaced>,
	left: Vec<String>,
	replaced_actions: Vec<String>,
	unlisted: Option<Unlisted>,
	/// The last write may not have landed. Memory holds what it wrote.
	unsettled: bool,
}

/// Move past the next line, which is settled.
fn settle_part(parts: &[Part], sent: &mut usize, attempt: &mut Attempt) -> Result<(), Error> {
	if *sent >= parts.len() {
		return Err(Error::state(FILE, "a reply has no line left to send"));
	}
	*sent += 1;
	*attempt = Attempt::Unsent;
	Ok(())
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
				return Err(Error::unreadable(FILE, "a turn's number was never issued"));
			}
			if rows.insert(row.id, row.phase).is_some() {
				return Err(Error::unreadable(FILE, "two turns share a number"));
			}
		}
		if document.replaced.len() > MAX_REPLACED {
			return Err(Error::unreadable(
				FILE,
				"more replaced lines than the session holds receipts",
			));
		}
		let mut operations = BTreeSet::new();
		if !document.replaced.iter().all(|line| operations.insert(&line.operation)) {
			return Err(Error::unreadable(FILE, "two replaced lines share an operation"));
		}
		for (records, what) in [
			(&document.left, "left receipts"),
			(&document.replaced_actions, "replaced actions"),
		] {
			let distinct: BTreeSet<_> = records.iter().collect();
			if records.len() > MAX_REPLACED || distinct.len() < records.len() {
				return Err(Error::unreadable(
					FILE,
					format!("{what} repeat or outnumber the session's places"),
				));
			}
		}
		admission::validate(&document.scheduled, &rows, document.next_turn)?;
		if document.private.len() > MAX_OPEN
			|| document.private.iter().any(|(id, speech)| {
				rows.get(id)
					.and_then(Phase::conversation)
					.is_none_or(|c| c.as_str() != speech.scope.conversation())
					|| speech.scope.kind() != crate::bot::rooms::Kind::Direct
					|| speech.text.len() > crate::bot::context::MAX_TEXT_BYTES + 6
			}) {
			return Err(Error::unreadable(
				FILE,
				"private speech does not belong to an open direct turn",
			));
		}
		Ok(Some(Self {
			scheduled: document.scheduled,
			private: document.private,
			cursor: document.cursor,
			cursor_seq: document.cursor_seq,
			next_turn: document.next_turn,
			notices: document.notices,
			rows,
			replaced: document.replaced,
			left: document.left,
			replaced_actions: document.replaced_actions,
			unlisted: document.unlisted,
			unsettled: false,
		}))
	}

	/// The conversation of turn `id` while it is open, read from the ledger of
	/// the bot directory `root` without its lease, so a verb a turn runs can
	/// check the turn it names beside the serving bot.
	pub fn running_turn_in(root: &std::path::Path, id: TurnId) -> Result<Option<ConversationId>, Error> {
		let Some(document) = store::read_unleased_bounded::<Document>(root, FILE, MAX_LEDGER_BYTES)? else {
			return Ok(None);
		};
		Ok(document
			.turns
			.into_iter()
			.find(|row| row.id == id && row.phase.is_running())
			.and_then(|row| row.phase.conversation().cloned()))
	}

	/// A first ledger whose cursor is the head of activity, written before the
	/// bot serves, so history from before the bot existed is never answered.
	pub fn start(store: &Store, cursor: Cursor) -> Result<Self, Error> {
		let ledger = Self {
			scheduled: BTreeMap::new(),
			private: BTreeMap::new(),
			cursor,
			cursor_seq: Seq(0),
			next_turn: TurnId(0),
			notices: 0,
			rows: BTreeMap::new(),
			replaced: Vec::new(),
			left: Vec::new(),
			replaced_actions: Vec::new(),
			unlisted: None,
			unsettled: false,
		};
		ledger.persist(store)?;
		Ok(ledger)
	}

	fn encode(&self) -> Result<Vec<u8>, Error> {
		let document = Document {
			scheduled: self.scheduled.clone(),
			private: self.private.clone(),
			cursor: self.cursor.clone(),
			cursor_seq: self.cursor_seq,
			next_turn: self.next_turn,
			notices: self.notices,
			turns: self
				.rows
				.iter()
				.map(|(id, phase)| Row {
					id: *id,
					phase: phase.clone(),
				})
				.collect(),
			replaced: self.replaced.clone(),
			left: self.left.clone(),
			replaced_actions: self.replaced_actions.clone(),
			unlisted: self.unlisted,
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
	/// or may have been. A change kept on a write that may not have landed is
	/// answered with its value, and [`Ledger::durable`] reports the write.
	fn commit<T>(&mut self, store: &Store, change: impl FnOnce(&mut Self) -> Result<T, Error>) -> Result<T, Error> {
		self.durable(store)?;
		let mut next = self.clone();
		let value = change(&mut next)?;
		match next.persist(store) {
			Ok(()) => {
				*self = next;
				Ok(value)
			}
			Err(Error::Unsettled(_)) => {
				*self = next;
				self.unsettled = true;
				Ok(value)
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

	/// Whether the file holds what memory holds: no write since the last one
	/// that landed may have failed.
	pub fn is_settled(&self) -> bool {
		!self.unsettled
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

	/// The turns whose verbs own their actions and notes: those whose harness
	/// may still run. A turn that fixed its reply no longer has a harness, so
	/// the serving loop settles what its actions left, whether or not the
	/// reply is delivered yet.
	pub fn running(&self) -> Vec<TurnId> {
		self.rows
			.iter()
			.filter(|(_, phase)| phase.is_running())
			.map(|(id, _)| *id)
			.collect()
	}

	/// How many turns have stopped running since the bot directory was first
	/// served, whether they are sending their reply or finished. It grows when
	/// a turn's verbs hand its actions to the serving loop.
	pub fn ended(&self) -> u64 {
		let running = self.rows.values().filter(|phase| phase.is_running()).count();
		self.next_turn
			.0
			.saturating_sub(self.notices)
			.saturating_sub(u64::try_from(running).unwrap_or(u64::MAX))
	}

	/// The conversations with a turn that still needs work.
	pub fn open_conversations(&self) -> BTreeSet<ConversationId> {
		self.rows.values().filter_map(Phase::conversation).cloned().collect()
	}

	/// The operations of the lines the session may hold a receipt of: one per
	/// sending turn, its current line once it was sent.
	pub fn sent(&self) -> Vec<String> {
		self.rows
			.values()
			.filter_map(|phase| match phase {
				Phase::Sending {
					parts, sent, attempt, ..
				} if attempt.is_sent() => parts.get(*sent).map(|part| part.operation.clone()),
				_ => None,
			})
			.collect()
	}

	/// How many turns have finished since the bot directory was first served.
	/// Turn numbers are never reused and the ledger keeps the next one, so
	/// every number below it that is not open has finished, across restarts.
	pub fn finished(&self) -> u64 {
		let open = self
			.rows
			.values()
			.filter(|phase| phase.is_open() && !phase.is_notice())
			.count();
		self.next_turn
			.0
			.saturating_sub(self.notices)
			.saturating_sub(u64::try_from(open).unwrap_or(u64::MAX))
	}

	/// How many open turns are sending their reply.
	pub fn sending(&self) -> usize {
		self.rows
			.values()
			.filter(|phase| matches!(phase, Phase::Sending { .. }))
			.count()
	}

	/// Add triggers read later to a turn whose harness has not started.
	pub fn extend(&mut self, store: &Store, id: TurnId, triggers: Vec<Trigger>) -> Result<(), Error> {
		if triggers.is_empty() || triggers.len() > self.room_in(id) {
			return Err(Error::state(FILE, "triggers were added past a turn's room"));
		}
		self.commit(store, |next| match next.rows.get_mut(&id).ok_or_else(missing)? {
			Phase::Running { asked, .. } => {
				asked.triggers.extend(triggers);
				Ok(())
			}
			_ => Err(Error::state(FILE, "triggers were added to a turn that is not running")),
		})
	}

	/// Record that a harness run starts, after `spent` runs have ended, and
	/// make the record durable, since the harness starts next. A record that
	/// cannot be made durable is answered with the failure and leaves memory as
	/// it was before, so a run that never started spends nothing. The file may
	/// hold either document, so the next change writes memory's first.
	pub fn start_run(&mut self, store: &Store, id: TurnId, spent_now: u32) -> Result<(), Error> {
		let before = self.clone();
		self.change(store, id, |phase| match phase {
			Phase::Running { runs, .. } => {
				*runs = Runs {
					spent: spent_now,
					progress: Progress::InFlight,
				};
				Ok(())
			}
			_ => Err(Error::state(FILE, "a run started for a turn that is not running")),
		})?;
		if let Err(error) = self.durable(store) {
			*self = before;
			self.unsettled = true;
			return Err(error);
		}
		Ok(())
	}

	/// Return a turn to what it was before [`Ledger::start_run`], for a run
	/// whose harness never started, so it spends nothing.
	pub fn unstart_run(&mut self, store: &Store, id: TurnId, before: Runs) -> Result<(), Error> {
		self.change(store, id, |phase| match phase {
			Phase::Running { runs, .. } => {
				*runs = before;
				Ok(())
			}
			_ => Err(Error::state(FILE, "a run was undone for a turn that is not running")),
		})
	}

	/// Record a run that ended without an answer and may be tried again.
	pub fn retry(&mut self, store: &Store, id: TurnId, why: String) -> Result<(), Error> {
		self.change(store, id, |phase| match phase {
			Phase::Running { runs, note, .. } => {
				runs.spent = runs.spent.saturating_add(1);
				runs.progress = Progress::Ready;
				*note = Some(bounded_note(why));
				Ok(())
			}
			_ => Err(Error::state(FILE, "a run ended for a turn that is not running")),
		})
	}

	/// Record a run the bot's own stop cut off. It spends nothing. Memory
	/// takes the change at once, and [`Ledger::durable`] or the next change
	/// writes it: a run the bot stopped is cut off whether or not the write
	/// lands, and until it lands a restart reads the run as in flight and
	/// counts it, as it counts any run a crash ended.
	pub fn cut_off(&mut self, id: TurnId) -> Result<(), Error> {
		match self.rows.get_mut(&id).ok_or_else(missing)? {
			Phase::Running { runs, .. } => runs.progress = Progress::CutOff,
			_ => return Err(Error::state(FILE, "a run was cut off for a turn that is not running")),
		}
		self.unsettled = true;
		Ok(())
	}

	/// Fix the reply before delivery. A successful turn may finish with no lines.
	pub fn answer(&mut self, store: &Store, id: TurnId, content: Content, parts: Vec<Part>) -> Result<(), Error> {
		if content == Content::Failure && parts.is_empty() {
			return Err(Error::state(FILE, "a failure reply needs a line"));
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

	/// Record that the next line is settled: kept, released, or given up on
	/// without being sent again.
	pub fn part_sent(&mut self, store: &Store, id: TurnId) -> Result<(), Error> {
		self.change_sending(store, id, |parts, sent, attempt, _| settle_part(parts, sent, attempt))
	}

	/// Record that the next line is settled by its echo while another access
	/// holds its receipt, and keep `line` beside the turns until the session
	/// says who holds it. One write holds both, so a restart never has the
	/// line settled without its record. A record past [`MAX_REPLACED`] cannot
	/// come from a session that holds at most that many receipts, and the
	/// oldest record is dropped to make room and returned, because a
	/// delivery that could not settle would wait forever.
	pub fn part_replaced(&mut self, store: &Store, id: TurnId, line: Replaced) -> Result<Option<Replaced>, Error> {
		self.commit(store, |next| {
			let Some(Phase::Sending {
				parts, sent, attempt, ..
			}) = next.rows.get_mut(&id)
			else {
				return Err(Error::state(FILE, "a send was recorded for a turn that is not sending"));
			};
			settle_part(parts, sent, attempt)?;
			next.replaced.retain(|held| held.operation != line.operation);
			next.replaced.push(line);
			Ok((next.replaced.len() > MAX_REPLACED).then(|| next.replaced.remove(0)))
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
					Attempt::Sent { .. },
					Attempt::Sent { .. } | Attempt::Committed { .. } | Attempt::Releasing { .. },
				)
				| (Attempt::Committed { .. }, Attempt::Committed { .. } | Attempt::Releasing { .. })
				| (Attempt::Releasing { .. }, Attempt::Releasing { .. }) => attempt.base() == next.base(),
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

	/// Replace the lines not yet sent with one failure line. A line already
	/// sent is replaced only on the session's answer that its operation did
	/// not post: a refusal of its first send, or, after a refused resend, a
	/// look that finds no receipt and a complete read that finds no echo. So a
	/// line that may have posted is never replaced.
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
		self.commit(store, |next| {
			let phase = next.rows.get_mut(&id).ok_or_else(missing)?;
			let covered = match phase {
				Phase::Running { asked, .. } => Covered::of(&asked.triggers),
				Phase::Sending { covered, .. } => covered.clone(),
				Phase::Done { .. } => return Ok(()),
			};
			*phase = Phase::Done { covered };
			next.close_occurrence(id);
			next.private.remove(&id);
			Ok(())
		})
	}

	/// Move the cursor to `cursor`, whose next event gets number `seq`, unless
	/// it stands there or past it already, and drop every finished turn the
	/// cursor has passed, including turns that finished after it moved.
	/// Returns whether the ledger changed.
	pub fn advance(&mut self, store: &Store, cursor: &Cursor, seq: Seq) -> Result<bool, Error> {
		let moves = seq > self.cursor_seq;
		let next_seq = seq.max(self.cursor_seq);
		let passed = |phase: &Phase| matches!(phase, Phase::Done { covered } if covered.events.is_empty() || covered.last < next_seq);
		if !moves && !self.rows.values().any(passed) {
			return Ok(false);
		}
		self.commit(store, |next| {
			if moves {
				next.cursor = cursor.clone();
				next.cursor_seq = seq;
			}
			next.rows.retain(|_, phase| !passed(phase));
			Ok(true)
		})
	}
}

#[cfg(test)]
mod tests;
