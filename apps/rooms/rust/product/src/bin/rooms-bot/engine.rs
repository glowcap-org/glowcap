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
//! reports it paused or revoked (`env::access_of`), a second signal ends every
//! turn that is thinking, and each goes back to the front of its conversation
//! to run again once the access works. A revoked access is final for its link:
//! the loop stops as it does for a signal and returns [`Error::Access`].
mod backoff;
mod checkins;
mod deliver;
mod env;
mod head;
mod intake;
mod lanes;
mod reaching;
mod read;
mod reset;
mod settle_old;
mod think;

use super::{
	classify::Seq,
	error::{Error, LinkStage},
	gate::Gate,
	ledger::{Content, Ledger, Part, Phase, TurnId},
	reply,
	rooms::{ConversationId, Cursor, READ_DEADLINE, Rooms, RoomsError, RoomsErrorKind, Wait},
	status::{Access, Activity},
	store::Store,
	words,
};
pub use backoff::Backoff;
pub use deliver::{receipt, settle_replaced};
pub use env::{Core, Env, Publishing};
pub(crate) use env::{access_of, ends_serving};
use futures_util::{StreamExt, stream::FuturesUnordered};
pub use head::head;
use lanes::{Lanes, Left};
use reaching::{Reached, Reaching};
use read::{ReadPace, read_backoff};
pub use settle_old::settle_old_lines;
use std::{
	collections::{BTreeMap, BTreeSet, btree_map::Entry},
	future::{Future, pending},
	pin::Pin,
	time::Duration,
};
use tokio::{
	sync::watch,
	time::{Instant, sleep, sleep_until, timeout},
};

/// Turns running the harness at once across conversations.
pub const MAX_TURNS: usize = 2;
/// How long shutdown waits for running turns to stop.
const STOP_GRACE: Duration = Duration::from_secs(15);
/// The longest reason a failure line gives.
const MAX_REASON_BYTES: usize = 300;

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

/// The line posted in place of an answer, with its reason cut to a short line.
pub fn failure_line(reason: &str) -> String {
	format!(
		"{}: {}.",
		words::COULD_NOT_ANSWER,
		reply::prefix(reason, MAX_REASON_BYTES)
	)
}

/// Log a stage's failure and show it in `status`.
pub fn report_failure<R: Rooms>(env: &Env<'_, R>, id: TurnId, during: Activity, error: &Error) {
	env.store.log(&format!("turn {}: {error}", id.0));
	env.facts.borrow_mut().failed(during, error);
}

/// A one-line failure reply with its own operation.
pub fn failure_part<R: Rooms>(env: &Core<'_, R>, id: TurnId, reason: &str) -> Result<Part, Error> {
	let mut text = failure_line(reason);
	if env.ledger.borrow().scheduled(id).is_some() {
		text.insert_str(0, super::reminders::CHECK_IN_PREFIX);
	}
	Ok(Part {
		operation: crate::bot::identity::new_action(env.store.root())?,
		text,
	})
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Stage {
	Think,
	Notice,
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
	/// Replies a previous bot left sending. They go out once the session
	/// has answered a read, because a send under access it has not accepted
	/// would give up the reply.
	unsent: Vec<(TurnId, ConversationId, Stage)>,
	/// How many turns each conversation has started this hour.
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
					"turn {} {} {}",
					id.0,
					words::TURN_STARTED,
					conversation.as_str()
				));
			}
		}
		let env = self.env;
		let mut stop = match stage {
			Stage::Think => self.halt.subscribe(),
			Stage::Deliver | Stage::Notice => self.stop.clone(),
		};
		self.turns.push(Box::pin(async move {
			let step = if waited(delay, &mut stop).await {
				match stage {
					Stage::Think => think::run(env, id, &mut stop).await,
					Stage::Deliver | Stage::Notice => deliver::run(env, id, &mut stop).await,
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

	/// Whether a turn may think now: the link is reached and the access is
	/// active.
	fn may_think(&self) -> bool {
		self.env.is_linked() && self.env.facts.borrow().access == Access::Active
	}

	/// Start the oldest waiting turn of an idle conversation while a harness
	/// slot is free and the access is active.
	fn start_turns(&mut self) {
		if !self.may_think() {
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

	/// Start the resumed replies once the link is reached. A read has just
	/// answered, so the access is active, and one that changes later is held by
	/// the delivery loop's wait for an active access.
	fn start_sends(&mut self) {
		if !self.env.is_linked() {
			return;
		}
		for (id, conversation, stage) in std::mem::take(&mut self.unsent) {
			self.spawn(id, conversation, stage, Duration::ZERO);
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
				"turn {} {} {} after {:.1} seconds: {outcome}",
				id.0,
				words::TURN_FINISHED,
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
				let outcome = match self.env.ledger.borrow().phase(id) {
					Some(Phase::Sending {
						content: Content::Failure,
						..
					}) => "failed",
					Some(Phase::Sending { parts, .. }) if parts.is_empty() => "no reply",
					_ => "answered",
				};
				self.thought(id, &conversation, outcome);
				self.retries.remove(&id);
				self.spawn(id, conversation, Stage::Deliver, Duration::ZERO);
			}
			Ok(Step::Finished) => {
				self.retries.remove(&id);
				self.env.facts.borrow_mut().recovered(Activity::Saving);
				if stage != Stage::Notice {
					self.lanes.release(&conversation);
				}
			}
			Ok(Step::Stopped) if stage == Stage::Think && !self.stopped() => self.halted(id, &conversation),
			Ok(Step::Stopped) => self.thought(id, &conversation, "stopped"),
			Err(error) => self.turn_failed(id, conversation, stage, error),
		}
		self.publish();
	}

	/// A stage that failed is tried again after a wait. A thinking turn that
	/// failed while it may not think, as one whose halt could not record its
	/// cut-off, goes back to its conversation and starts again with the
	/// others once the access is active.
	fn turn_failed(&mut self, id: TurnId, conversation: ConversationId, stage: Stage, error: Error) {
		let during = match stage {
			Stage::Think => Activity::Thinking,
			Stage::Deliver | Stage::Notice => Activity::Saving,
		};
		report_failure(self.env, id, during, &error);
		if self.env.ledger.borrow().phase(id).is_none() {
			self.thought(id, &conversation, "left the ledger");
			self.retries.remove(&id);
			self.env.replies.borrow_mut().remove(&id);
			self.env.unsaved.borrow_mut().remove(&id);
			if stage != Stage::Notice {
				self.lanes.release(&conversation);
			}
			return;
		}
		if stage == Stage::Think && !self.may_think() {
			self.halted(id, &conversation);
			return;
		}
		let wait = self.retries.entry(id).or_insert_with(Backoff::standard).next();
		self.spawn(id, conversation, stage, wait);
	}

	/// Park a thinking turn the halt ended, to start again once the access is
	/// active. A halt gives the run after it a whole deadline, so the turn's
	/// deadline is dropped here whichever way the turn reached the halt: its
	/// think ended, failed, or was still waiting out a retry.
	fn halted(&mut self, id: TurnId, conversation: &ConversationId) {
		self.env.replies.borrow_mut().remove(&id);
		self.thought(id, conversation, words::HALTED);
		self.lanes.halted(conversation, id);
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
		let settled = intake::admit(self)
			.and_then(|()| {
				self.start_sends();
				self.start_turns();
				self.advance()
			})
			.and_then(|()| {
				// The cursor update dropped finished rows that kept the oldest
				// unheld trigger out, so it gets its turn now and not at the
				// next read.
				if self.lanes.oldest_waiting().is_none() || !self.env.ledger.borrow().has_room() {
					return Ok(());
				}
				intake::admit(self)?;
				self.start_sends();
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

/// Return every turn a previous bot left open to its lane, oldest first.
/// A conversation runs one turn at a time, so a delivering turn behind an
/// earlier open turn of its conversation is refused.
fn resume<R: Rooms>(state: &mut Loop<'_, R>) -> Result<(), Error> {
	let open = state.env.ledger.borrow().open();
	let mut seen = BTreeSet::new();
	for id in open {
		let phase = state.env.ledger.borrow().phase(id).cloned();
		match phase {
			Some(Phase::Running { asked, .. }) => {
				state.lanes.resume(&asked.conversation, id, Left::Waiting);
				seen.insert(asked.conversation);
			}
			Some(Phase::Sending {
				conversation,
				content: Content::Availability,
				..
			}) => {
				state.unsent.push((id, conversation, Stage::Notice));
			}
			Some(Phase::Sending { conversation, .. }) => {
				if !seen.insert(conversation.clone()) {
					return Err(Ledger::invariant("a reply is sending behind an earlier turn"));
				}
				state.lanes.resume(&conversation, id, Left::Delivering);
				state.unsent.push((id, conversation, Stage::Deliver));
			}
			Some(Phase::Done { .. }) | None => {}
		}
	}
	Ok(())
}

enum Woke {
	CheckIn(super::reminders::CheckIn),
	Stop,
	Turn(Ended),
	/// The access stopped serving, so what is thinking ends.
	Halted,
	Read(Result<super::rooms::Batch, RoomsError>),
	Held,
}

/// What reading the session carries between reads: the link's storing, the
/// waits, and what the last read said.
struct Reads<F> {
	pace: ReadPace,
	reaching: Reaching,
	/// Stores what the session's first answer stores: see [`serve`].
	reached: F,
}

/// Serve until `shutdown`. `reached` runs once the session has first
/// answered a read, with its failure ending the loop, and the link is stored
/// from then on. `stage` says how the link stands until then, and
/// `env::ends_serving` says which answers end the loop at each stage.
pub async fn serve<'a, R: Rooms>(
	env: &'a Env<'a, R>,
	mut shutdown: watch::Receiver<bool>,
	mut checkins: tokio::sync::mpsc::Receiver<super::reminders::CheckIn>,
	stage: LinkStage,
	reached: impl FnMut() -> Result<(), Error>,
) -> Result<(), Error> {
	let (stop, stop_signal) = watch::channel(false);
	let mut state = Loop::new(env, stop_signal);
	resume(&mut state)?;
	state.publish();
	let mut reads = Reads {
		pace: ReadPace::new(),
		reaching: Reaching::new(stage),
		reached,
	};
	let outcome = loop {
		if let Err(error) = state.settle() {
			break Err(error);
		}
		if let Err(error) = state.revoked(&reads.reaching) {
			break Err(error);
		}
		let (woke, began) = state.wake(&mut shutdown, &mut checkins, &reads.pace).await;
		let step = match woke {
			Woke::Stop => break Ok(()),
			Woke::Halted => {
				state.halt_thinking();
				Ok(())
			}
			Woke::Turn(ended) => {
				state.ended(ended);
				Ok(())
			}
			Woke::Held => Ok(()),
			Woke::CheckIn(check) => checkins::accept(&mut state, check).await,
			Woke::Read(read) => state.read_done(&mut reads, began, read),
		};
		if let Err(error) = step {
			break Err(error);
		}
	};
	state.drain(&stop).await;
	outcome
}

impl<'a, R: Rooms> Loop<'a, R> {
	fn new(env: &'a Env<'a, R>, stop: watch::Receiver<bool>) -> Self {
		let ledger = env.ledger.borrow();
		Self {
			env,
			stop,
			lanes: Lanes::default(),
			turns: FuturesUnordered::new(),
			thinking: 0,
			retries: BTreeMap::new(),
			began: BTreeMap::new(),
			read: Read {
				cursor: ledger.cursor().clone(),
				seq: ledger.cursor_seq(),
			},
			held: None,
			unsent: Vec::new(),
			gate: Gate::new(env.config.conversation_limit),
			halt: watch::channel(false).0,
		}
	}

	/// A send can meet a revoked access while reads are stopped, so the
	/// access ends serving wherever it was seen.
	fn revoked(&self, reaching: &Reaching) -> Result<(), Error> {
		if self.env.facts.borrow().access != Access::Revoked {
			return Ok(());
		}
		let cause = "this access was revoked".to_owned();
		self.env.store.log(&format!("serving: {cause}"));
		Err(Error::access_ended(reaching.stage(self.env), cause))
	}

	/// Wait for the next thing the loop acts on, and say how many access
	/// changes had happened when a read in it began, so a read that began
	/// before a send found the access stopped does not open it again.
	async fn wake(
		&mut self,
		shutdown: &mut watch::Receiver<bool>,
		checkins: &mut tokio::sync::mpsc::Receiver<super::reminders::CheckIn>,
		pace: &ReadPace,
	) -> (Woke, u64) {
		let env = self.env;
		let reading = read::wanted(self.lanes.waiting(), env.facts.borrow().access, self.held.is_some());
		let after = self.read.cursor.clone();
		let began = env.access_changes.get();
		let held_until = self.held.as_ref().map(|(until, _)| *until);
		let woke = tokio::select! {
			biased;
			() = stopping(shutdown) => Woke::Stop,
			() = env.halted.notified() => Woke::Halted,
			Some(check) = checkins.recv() => Woke::CheckIn(check),
			Some(ended) = self.turns.next(), if !self.turns.is_empty() => Woke::Turn(ended),
			() = sleep_until(held_until.unwrap_or_else(Instant::now)), if held_until.is_some() => Woke::Held,
			read = async {
				sleep_until(pace.read_at).await;
				timeout(READ_DEADLINE, env.rooms.events(&after, if pace.failing { Wait::Poll } else { Wait::Hold })).await
			}, if reading => Woke::Read(read.unwrap_or_else(|_| {
				Err(RoomsError::new(RoomsErrorKind::Unreachable, "a read of events did not finish in time"))
			})),
		};
		(woke, began)
	}

	/// Act on what a read answered. A read that succeeded stores the link
	/// first, and the batch is taken once it is stored.
	fn read_done<F: FnMut() -> Result<(), Error>>(
		&mut self,
		reads: &mut Reads<F>,
		began: u64,
		read: Result<super::rooms::Batch, RoomsError>,
	) -> Result<(), Error> {
		let env = self.env;
		match read {
			Ok(batch) => {
				reads.pace.read(env);
				env.access_active_since(began, Activity::Receiving);
				match reads.reaching.run(env, &mut reads.reached) {
					Reached::Go => {}
					// The next read returns at once, on the backoff, and not
					// after a wait on a quiet session.
					Reached::Again(wait) => {
						reads.pace.retry_after(wait);
						return Ok(());
					}
					Reached::End(error) => return Err(error),
				}
				self.start_sends();
				intake::take(self, batch);
				Ok(())
			}
			Err(error) if ends_serving(error.kind) => {
				env.access_failed(Activity::Receiving, &error);
				env.store.log(&format!("receiving: {error}"));
				Err(Error::access_ended(reads.reaching.stage(env), error.to_string()))
			}
			Err(error) => {
				reads.pace.failed(env, &error);
				Ok(())
			}
		}
	}

	/// End the loop: stop every stage, and wait for them so no harness
	/// outlives the bot, but not forever. Dropping a stage ends its group,
	/// which does not reach the agent's tool commands (`group.rs`).
	async fn drain(&mut self, stop: &watch::Sender<bool>) {
		stop.send_replace(true);
		self.halt_thinking();
		let drained = timeout(STOP_GRACE, async {
			while let Some(ended) = self.turns.next().await {
				self.ended(ended);
			}
		})
		.await;
		if drained.is_err() {
			self.env.store.log("running turns did not stop in time and were ended");
		}
		self.publish();
	}
}
