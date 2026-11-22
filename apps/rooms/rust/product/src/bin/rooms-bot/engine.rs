//! The loop. It reads events from the session, sorts each into context or a
//! trigger, runs one turn at a time per conversation, and moves the durable
//! cursor only past events that are either finished with or held by a turn.
//!
//! A turn has two stages. Thinking runs the harness and fixes the reply in
//! the ledger, and at most [`MAX_TURNS`] turns think at once. Delivering sends
//! the reply's lines and holds no harness, so it never counts against that
//! bound. Every exit from the loop sets one stop signal that every stage
//! watches, and the loop then waits a bounded time for them to stop.
//!
//! A turn starts only while the bot's access is active. When the session
//! reports it paused, revoked, or refused, a second signal ends every turn
//! that is thinking, and each goes back to the front of its conversation to
//! run again once the access works.
mod backoff;
mod deliver;
mod handover;
mod head;
mod intake;
mod lanes;
mod reason;
mod reset;
mod think;

use super::{
	classify::Seq,
	config::Config,
	conversations::Conversations,
	error::Error,
	gate::Gate,
	group::{self, Reaped},
	harness::Harness,
	ledger::{Content, Ledger, Part, Phase, TurnId},
	reply,
	rooms::{ConversationId, Cursor, READ_DEADLINE, Rooms, RoomsError, RoomsErrorKind},
	sessions::Sessions,
	status::{Access, Activity, Facts},
	store::Store,
};
pub use backoff::Backoff;
use futures_util::{StreamExt, stream::FuturesUnordered};
pub use handover::hand_over;
pub use head::head;
use lanes::Lanes;
use std::{
	cell::{Cell, RefCell},
	collections::{BTreeMap, BTreeSet, btree_map::Entry},
	future::{Future, pending},
	pin::Pin,
	time::Duration,
};
use tokio::{
	sync::{Notify, watch},
	time::{Instant, sleep, sleep_until, timeout},
};

/// Turns running the harness at once across conversations.
pub const MAX_TURNS: usize = 2;
/// Triggers waiting for room in the ledger. Past it the bot stops reading,
/// and the session keeps what it has not delivered.
const MAX_QUEUED: usize = 256;
/// How long shutdown waits for running turns to stop.
const STOP_GRACE: Duration = Duration::from_secs(15);
/// The longest reason a failure line gives.
const MAX_REASON_BYTES: usize = 300;

pub struct Env<'a, R: Rooms> {
	pub rooms: &'a R,
	pub store: &'a Store,
	pub config: &'a Config,
	pub harness: &'a dyn Harness,
	pub ledger: RefCell<Ledger>,
	pub sessions: RefCell<Sessions>,
	pub conversations: RefCell<Conversations>,
	pub facts: RefCell<Facts>,
	/// Woken when a failed call first finds the access paused, revoked, or
	/// refused, from a read or from a send, so the loop ends what is
	/// thinking at once.
	pub halted: Notify,
	/// Counts changes of `facts.access`, so a call that began before one
	/// can tell its answer is older than the access state.
	pub access_changes: Cell<u64>,
}

impl<R: Rooms> Env<'_, R> {
	/// Write the status file with what the ledger says now.
	pub fn publish(&self) {
		let ledger = self.ledger.borrow();
		let mut facts = self.facts.borrow_mut();
		facts.cursor = ledger.cursor().clone();
		facts.open_turns = ledger.open().len();
		facts.sending = ledger.sending();
		facts.turns_finished = ledger.finished();
		facts.publish(self.store);
	}

	/// Record what a failed call says about the bot's access.
	pub fn access_failed(&self, during: Activity, error: &RoomsError) {
		let mut facts = self.facts.borrow_mut();
		if let Some(access) = access_of(error.kind) {
			if facts.access != access {
				self.halted.notify_one();
				self.access_changes.set(self.access_changes.get() + 1);
			}
			facts.access = access;
		}
		facts.failed(during, error);
	}

	/// A call succeeded, so access is active and that activity has recovered.
	pub fn access_active(&self, during: Activity) {
		let mut facts = self.facts.borrow_mut();
		if facts.access != Access::Active {
			self.access_changes.set(self.access_changes.get() + 1);
		}
		facts.access = Access::Active;
		facts.recovered(during);
	}

	/// A call that began when `access_changes` read `began` succeeded. It
	/// marks the access active only when nothing changed the access since,
	/// so a send already on its way when a read found the access paused
	/// does not open it again.
	pub fn access_active_since(&self, began: u64, during: Activity) {
		if self.access_changes.get() == began {
			self.access_active(during);
		} else {
			self.facts.borrow_mut().recovered(during);
		}
	}
}

/// What an access error says about the grant, when it says anything.
fn access_of(kind: RoomsErrorKind) -> Option<Access> {
	match kind {
		RoomsErrorKind::Paused => Some(Access::Paused),
		RoomsErrorKind::Revoked => Some(Access::Revoked),
		RoomsErrorKind::Refused => Some(Access::Refused),
		RoomsErrorKind::Unreachable | RoomsErrorKind::Uncertain | RoomsErrorKind::Exists => None,
	}
}

/// Resolve once `stop` holds true. A stop whose sender is gone never resolves,
/// so a dropped sender is never read as a stop.
pub async fn stopping(stop: &mut watch::Receiver<bool>) {
	while !*stop.borrow_and_update() {
		if stop.changed().await.is_err() {
			pending::<()>().await;
		}
	}
}

/// Wait `delay`, or less when `stop` comes first. Returns whether the whole
/// wait passed.
pub async fn waited(delay: Duration, stop: &mut watch::Receiver<bool>) -> bool {
	if *stop.borrow() {
		return false;
	}
	if delay.is_zero() {
		return true;
	}
	tokio::select! {
		biased;
		() = stopping(stop) => false,
		() = sleep(delay) => true,
	}
}

/// A new operation id for one line.
pub fn operation() -> Result<String, Error> {
	let mut bytes = [0; 16];
	rooms_platform::entropy::fill(&mut bytes).map_err(|error| Error::Entropy(error.to_string()))?;
	Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

/// The line posted in place of an answer, with its reason cut to a short line.
pub fn failure_line(reason: &str) -> String {
	format!("I could not answer that: {}.", reply::prefix(reason, MAX_REASON_BYTES))
}

/// A one-line failure reply with its own operation.
pub fn failure_part(reason: &str) -> Result<Part, Error> {
	Ok(Part {
		operation: operation()?,
		text: failure_line(reason),
	})
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Stage {
	Think,
	Deliver,
}

/// Where a stage left its turn.
#[derive(Debug, PartialEq, Eq)]
pub enum Step {
	/// The reply is fixed and its lines can go out.
	Deliver,
	Finished,
	/// The stop signal ended the stage. The ledger says where to resume.
	Stopped,
}

struct Ended {
	id: TurnId,
	conversation: ConversationId,
	stage: Stage,
	step: Result<Step, Error>,
}

type Running<'a> = Pin<Box<dyn Future<Output = Ended> + 'a>>;

/// Where reading stands: the cursor to read after, and the number its next
/// event gets.
struct Read {
	cursor: Cursor,
	seq: Seq,
}

struct Loop<'a, R: Rooms> {
	env: &'a Env<'a, R>,
	stop: watch::Receiver<bool>,
	lanes: Lanes,
	turns: FuturesUnordered<Running<'a>>,
	thinking: usize,
	retries: BTreeMap<TurnId, Backoff>,
	/// When each turn that is thinking began, for the log.
	began: BTreeMap<TurnId, Instant>,
	read: Read,
	/// Until then the loop neither reads nor starts turns, after a state
	/// write failed.
	held: Option<(Instant, Backoff)>,
	/// Who may start work, and how much.
	gate: Gate,
	/// Ends the turns that are thinking. Each halt sends on it and puts a new
	/// channel in its place, so a turn started afterwards is not ended.
	halt: watch::Sender<bool>,
}

impl<'a, R: Rooms> Loop<'a, R> {
	fn stopped(&self) -> bool {
		*self.stop.borrow()
	}

	fn publish(&self) {
		self.env.facts.borrow_mut().queued = self.lanes.waiting();
		self.env.publish();
	}

	fn spawn(&mut self, id: TurnId, conversation: ConversationId, stage: Stage, delay: Duration) {
		if self.stopped() {
			return;
		}
		if stage == Stage::Think {
			self.thinking += 1;
			if let Entry::Vacant(slot) = self.began.entry(id) {
				slot.insert(Instant::now());
				self.env.store.log(&format!(
					"turn {} started in conversation {}",
					id.0,
					conversation.as_str()
				));
			}
		}
		let env = self.env;
		let mut stop = match stage {
			Stage::Think => self.halt.subscribe(),
			Stage::Deliver => self.stop.clone(),
		};
		self.turns.push(Box::pin(async move {
			let step = if waited(delay, &mut stop).await {
				match stage {
					Stage::Think => think::run(env, id, &mut stop).await,
					Stage::Deliver => deliver::run(env, id, &mut stop).await,
				}
			} else {
				Ok(Step::Stopped)
			};
			Ended {
				id,
				conversation,
				stage,
				step,
			}
		}));
	}

	/// End every turn that is thinking: the bot is stopping, or its access
	/// stopped working.
	fn halt_thinking(&mut self) {
		let (next, _) = watch::channel(false);
		std::mem::replace(&mut self.halt, next).send_replace(true);
	}

	/// Start the oldest waiting turn of an idle conversation while a harness
	/// slot is free and the access is active.
	fn start_turns(&mut self) {
		if self.env.facts.borrow().access != Access::Active {
			return;
		}
		while self.thinking < MAX_TURNS && !self.stopped() {
			let Some((conversation, id)) = self.lanes.next() else {
				break;
			};
			self.lanes.started(&conversation);
			self.spawn(id, conversation, Stage::Think, Duration::ZERO);
		}
	}

	/// Move the cursor to just before the oldest trigger no turn holds, or to
	/// where reading stands when none waits.
	fn advance(&mut self) -> Result<(), Error> {
		let (cursor, seq) = match self.lanes.oldest_waiting() {
			Some((before, seq)) => (before.clone(), seq),
			None => (self.read.cursor.clone(), self.read.seq),
		};
		if self.env.ledger.borrow_mut().advance(self.env.store, &cursor, seq)? {
			self.publish();
		}
		Ok(())
	}

	/// Log how a turn's thinking ended and how long it took. The log names
	/// the turn and its conversation, never what was said.
	fn thought(&mut self, id: TurnId, conversation: &ConversationId, outcome: &str) {
		if let Some(began) = self.began.remove(&id) {
			self.env.store.log(&format!(
				"turn {} finished in conversation {} after {:.1} seconds: {outcome}",
				id.0,
				conversation.as_str(),
				began.elapsed().as_secs_f64()
			));
		}
	}

	fn ended(&mut self, ended: Ended) {
		let Ended {
			id,
			conversation,
			stage,
			step,
		} = ended;
		if stage == Stage::Think {
			self.thinking -= 1;
		}
		match step {
			Ok(Step::Deliver) => {
				let failed = matches!(
					self.env.ledger.borrow().phase(id),
					Some(Phase::Sending {
						content: Content::Failure,
						..
					})
				);
				self.thought(id, &conversation, if failed { "failed" } else { "answered" });
				self.retries.remove(&id);
				self.env.facts.borrow_mut().recovered(Activity::Thinking);
				self.spawn(id, conversation, Stage::Deliver, Duration::ZERO);
			}
			Ok(Step::Finished) => {
				self.retries.remove(&id);
				{
					let mut facts = self.env.facts.borrow_mut();
					facts.recovered(Activity::Thinking);
					facts.recovered(Activity::Saving);
				}
				self.lanes.release(&conversation);
			}
			Ok(Step::Stopped) if stage == Stage::Think && !self.stopped() => {
				self.thought(id, &conversation, "halted, because the access stopped working");
				self.lanes.halted(&conversation, id);
			}
			Ok(Step::Stopped) => self.thought(id, &conversation, "stopped"),
			Err(error) => self.turn_failed(id, conversation, stage, error),
		}
		self.publish();
	}

	/// A stage that failed is tried again after a wait. A thinking turn whose
	/// failure will not clear posts a failure line instead.
	fn turn_failed(&mut self, id: TurnId, conversation: ConversationId, stage: Stage, error: Error) {
		self.env.store.log(&format!("turn {}: {error}", id.0));
		let during = match stage {
			Stage::Think => Activity::Thinking,
			Stage::Deliver => Activity::Saving,
		};
		self.env.facts.borrow_mut().failed(during, &error);
		let phase = self.env.ledger.borrow().phase(id).cloned();
		match phase {
			None => {
				self.thought(id, &conversation, "left the ledger");
				self.retries.remove(&id);
				self.lanes.release(&conversation);
				return;
			}
			Some(Phase::Running { .. }) if !error.is_transient() => {
				let failed = failure_part("something went wrong on my side").and_then(|part| {
					self.env
						.ledger
						.borrow_mut()
						.answer(self.env.store, id, Content::Failure, vec![part])
				});
				match failed {
					Ok(()) => {
						self.thought(id, &conversation, "failed");
						return self.spawn(id, conversation, Stage::Deliver, Duration::ZERO);
					}
					Err(error) => self
						.env
						.store
						.log(&format!("turn {}: fixing its failure line: {error}", id.0)),
				}
			}
			Some(_) => {}
		}
		let wait = self.retries.entry(id).or_insert_with(Backoff::standard).next();
		self.spawn(id, conversation, stage, wait);
	}

	/// A state write the loop needs failed. Wait before trying again.
	fn hold(&mut self, error: &Error) {
		self.env.store.log(&format!("saving state: {error}"));
		self.env.facts.borrow_mut().failed(Activity::Saving, error);
		self.publish();
		let mut backoff = self.held.take().map_or_else(Backoff::standard, |(_, backoff)| backoff);
		self.held = Some((Instant::now() + backoff.next(), backoff));
	}

	/// Hold what was read in turns, start what can start, and move the cursor.
	/// Returns an error only for a failure that waiting cannot clear.
	fn settle(&mut self) -> Result<(), Error> {
		if self.held.as_ref().is_some_and(|(until, _)| Instant::now() < *until) {
			return Ok(());
		}
		let settled = intake::admit(self).and_then(|()| {
			self.start_turns();
			self.advance()
		});
		match settled {
			Ok(()) => {
				if self.held.take().is_some() {
					self.env.facts.borrow_mut().recovered(Activity::Saving);
					self.publish();
				}
				Ok(())
			}
			Err(error) if error.is_transient() => {
				self.hold(&error);
				Ok(())
			}
			Err(error) => Err(error),
		}
	}
}

/// End harness groups a killed bot left running, where their leader is
/// confirmed, and clear every record.
fn reap(store: &Store) -> Result<(), Error> {
	let groups = store.groups()?;
	let entries = std::fs::read_dir(&groups).map_err(Error::io("listing harness group records"))?;
	for entry in entries {
		let path = entry.map_err(Error::io("listing harness group records"))?.path();
		match group::reap(&path) {
			Reaped::Gone => {}
			Reaped::Ended(id) => store.log(&format!("ended harness group {id}, left running by a killed bot")),
			Reaped::Left(id, why) => store.log(&format!("left harness group {id} alone: {why}")),
			Reaped::Discarded(why) => store.log(&format!("discarded {}: {why}", path.display())),
		}
		if let Err(error) = group::forget(&path) {
			store.log(&format!("removing {}: {error}", path.display()));
		}
	}
	Ok(())
}

/// Hand every turn a previous bot left open back to its lane, oldest first.
/// A conversation runs one turn at a time, so a delivering turn behind an
/// earlier open turn of its conversation is refused.
fn resume<R: Rooms>(state: &mut Loop<'_, R>) -> Result<(), Error> {
	let open = state.env.ledger.borrow().open();
	let mut seen = BTreeSet::new();
	for id in open {
		let phase = state.env.ledger.borrow().phase(id).cloned();
		match phase {
			Some(Phase::Running { asked, .. }) => {
				state.lanes.resume(&asked.conversation, id, false);
				seen.insert(asked.conversation);
			}
			Some(Phase::Sending { conversation, .. }) => {
				if !seen.insert(conversation.clone()) {
					return Err(Ledger::invariant("a reply is sending behind an earlier turn"));
				}
				state.lanes.resume(&conversation, id, true);
				state.spawn(id, conversation, Stage::Deliver, Duration::ZERO);
			}
			Some(Phase::Done { .. }) | None => {}
		}
	}
	Ok(())
}

/// The wait after a failed read, and what it says about access.
fn read_failed<R: Rooms>(
	env: &Env<'_, R>,
	error: &RoomsError,
	standard: &mut Backoff,
	slow: &mut Backoff,
	reported: &mut Option<String>,
) -> Duration {
	env.access_failed(Activity::Receiving, error);
	env.publish();
	read_backoff(env.store, "receiving", error, [standard, slow], reported)
}

/// The wait after a failed read of activity. Paused, revoked, and refused
/// access changes only when a person acts, so it waits on the slow steps
/// and a connection failure on the standard ones. The log names a failure
/// once, after `during`. `reported` holds the one it last named, so a read
/// that fails the same way again adds no line.
fn read_backoff(
	store: &Store,
	during: &str,
	error: &RoomsError,
	[standard, slow]: [&mut Backoff; 2],
	reported: &mut Option<String>,
) -> Duration {
	let text = error.to_string();
	if reported.as_deref() != Some(text.as_str()) {
		store.log(&format!("{during}: {text}"));
		*reported = Some(text);
	}
	match access_of(error.kind) {
		Some(_) => slow.next(),
		None => standard.next(),
	}
}

enum Woke {
	Stop,
	Turn(Ended),
	/// The access stopped serving, so what is thinking ends.
	Halted,
	Read(Result<Result<super::rooms::Batch, RoomsError>, tokio::time::error::Elapsed>),
	Held,
}

/// Serve until `shutdown`. `announce` runs once the loop is ready.
pub async fn serve<'a, R: Rooms>(
	env: &'a Env<'a, R>,
	mut shutdown: watch::Receiver<bool>,
	announce: impl FnOnce(),
) -> Result<(), Error> {
	reap(env.store)?;
	let (stop, stop_signal) = watch::channel(false);
	let read = {
		let ledger = env.ledger.borrow();
		Read {
			cursor: ledger.cursor().clone(),
			seq: ledger.cursor_seq(),
		}
	};
	let mut state = Loop {
		env,
		stop: stop_signal,
		lanes: Lanes::default(),
		turns: FuturesUnordered::new(),
		thinking: 0,
		retries: BTreeMap::new(),
		began: BTreeMap::new(),
		read,
		held: None,
		gate: Gate::default(),
		halt: watch::channel(false).0,
	};
	resume(&mut state)?;
	state.publish();
	announce();
	let (mut standard, mut slow) = (Backoff::standard(), Backoff::slow());
	let mut read_at = Instant::now();
	// After a failed read the next one returns at once, so access that came
	// back shows as active without waiting out a read of a quiet session.
	let mut failing = false;
	let mut reported = None;
	let outcome = loop {
		if let Err(error) = state.settle() {
			break Err(error);
		}
		let reading = state.lanes.waiting() < MAX_QUEUED && state.held.is_none();
		let after = state.read.cursor.clone();
		let held_until = state.held.as_ref().map(|(until, _)| *until);
		let woke = tokio::select! {
			biased;
			() = stopping(&mut shutdown) => Woke::Stop,
			() = env.halted.notified() => Woke::Halted,
			Some(ended) = state.turns.next(), if !state.turns.is_empty() => Woke::Turn(ended),
			() = async { sleep_until(held_until.unwrap_or_else(Instant::now)).await }, if held_until.is_some() => Woke::Held,
			read = async {
				sleep_until(read_at).await;
				timeout(READ_DEADLINE, env.rooms.events(&after, !failing)).await
			}, if reading => Woke::Read(read),
		};
		match woke {
			Woke::Stop => break Ok(()),
			Woke::Halted => state.halt_thinking(),
			Woke::Turn(ended) => state.ended(ended),
			Woke::Held => {}
			Woke::Read(Ok(Ok(batch))) => {
				failing = false;
				standard.reset();
				slow.reset();
				if reported.take().is_some() {
					env.store.log("receiving: reading events works again");
				}
				env.access_active(Activity::Receiving);
				intake::take(&mut state, batch);
			}
			Woke::Read(Ok(Err(error))) => {
				failing = true;
				read_at = Instant::now() + read_failed(env, &error, &mut standard, &mut slow, &mut reported);
			}
			Woke::Read(Err(_)) => {
				failing = true;
				let error = RoomsError::new(RoomsErrorKind::Unreachable, "a read of events did not finish in time");
				read_at = Instant::now() + read_failed(env, &error, &mut standard, &mut slow, &mut reported);
			}
		}
	};
	stop.send_replace(true);
	state.halt_thinking();
	// Every stage watches the stop signal. Wait for them so no harness
	// outlives the bot, but not forever. Dropping a stage ends its group.
	let drained = timeout(STOP_GRACE, async {
		while let Some(ended) = state.turns.next().await {
			state.ended(ended);
		}
	})
	.await;
	if drained.is_err() {
		env.store.log("running turns did not stop in time and were ended");
	}
	state.publish();
	outcome
}
