//! The thinking stage of a turn: run the harness until it answers, or until
//! the turn has spent its runs, and fix the reply's lines in the ledger. Each
//! step writes the ledger before it acts and reads it to decide what comes
//! next, so a bot restarted at any point resumes here.
//!
//! The harness's effects are not undone by a failed write, so a run's result
//! is held in memory until the ledger takes it. A failed write of the reply is
//! retried with backoff and never runs the harness again while this process
//! lives. A bot that dies before that write lands reruns the turn after a
//! restart, because nothing durable says the harness already answered. A turn
//! the agent cannot answer is recorded once, for the room and the operator,
//! as a [`Cause`].
mod cause;
mod typing;
use super::{Backoff, Env, Step, failure_part, report_failure, reset, stopping, waited};
use crate::bot::words::{COULD_NOT_STOP_TYPING, SAVE_RETRIED_WITHOUT_RUNNING};
use crate::bot::{
	act, actions, config, context,
	error::Error,
	fault::{self, Fail},
	harness::{FailureKind, Turn},
	home, inbox,
	ledger::{Asked, Content, Ledger, MAX_RUNS, Part, Phase, Progress, Runs, TurnId},
	opens, prompt, reply,
	rooms::{ConversationId, Rooms, Typing},
	runner::{self, Finish, Heard, Place, Ran},
	status::Activity,
	store, words,
};
use cause::Cause;
use rooms_platform::storage::StorageError;
use std::time::Duration;
use tokio::{sync::watch, time::Instant};
use typing::{notice, typing};

/// What one run of the harness amounts to for the ledger.
enum Run {
	Answer(String),
	/// The run failed in a way another run may fix.
	Retry(FailureKind),
	/// Another run cannot help.
	GiveUp(Cause),
	/// The bot's stop ended a run that had started, so the ledger records it
	/// cut off.
	Stopped,
	/// The bot's stop came before the run started, so the ledger is as it was:
	/// no run is cut off, and one a crash left in flight stays counted.
	NotStarted,
}

/// What the runs of one reply share while this process serves it: the
/// deadline that bounds them all, and the kind of the last run that ended in
/// a retry, for the give-up after the last try. [`run`] keeps it while a
/// failure that may clear sends the turn back to think, and drops it once the
/// turn stops thinking, so a restart or a halt starts both afresh.
#[derive(Clone, Copy)]
pub struct Reply {
	ends: Instant,
	last_kind: Option<FailureKind>,
}

/// A reply whose ledger write has not landed. [`fix_reply`] keeps it while
/// a write may succeed on retry, including across a halt. A permanent write
/// failure replaces the answer with a failure line.
#[derive(Clone)]
pub struct Unsaved {
	content: Content,
	parts: Vec<Part>,
	/// The give-up this reply ends the turn with, recorded once the reply is
	/// saved, however many starts and halts that takes.
	cause: Option<Cause>,
}

/// Think, then close the turn's typing notice once it stops thinking. The
/// action budget closes earlier, as the reply is fixed (`close_budget`), so no
/// verb acts for the turn once its agent has stopped. A stopped turn keeps its
/// budget for the run that resumes it, and sends no notice: a halted access
/// would refuse it, and readers clear a notice nobody renews.
pub async fn run<R: Rooms>(env: &Env<'_, R>, id: TurnId, stop: &mut watch::Receiver<bool>) -> Result<Step, Error> {
	let conversation = match env.ledger.borrow().phase(id) {
		Some(Phase::Running { asked, .. }) => Some(asked.conversation.clone()),
		_ => None,
	};
	let step = match think(env, id, stop).await {
		Ok(step) => step,
		// A failure that waiting will not clear ends the turn with a failure
		// line, and the line's own write is retried like any reply.
		Err(error) if !error.is_transient() && matches!(env.ledger.borrow().phase(id), Some(Phase::Running { .. })) => {
			report_failure(env, id, Activity::Thinking, &error);
			env.replies.borrow_mut().remove(&id);
			fail_turn(env, id, "something went wrong on my side", None, stop).await?
		}
		Err(error) => return Err(error),
	};
	env.replies.borrow_mut().remove(&id);
	if let Some(conversation) = conversation
		&& !matches!(step, Step::Stopped)
		&& let Err(error) = notice(env, &conversation, Typing::Stop).await
	{
		// tolerant: readers clear the notice once nobody renews it.
		env.store
			.log(&format!("turn {}: {COULD_NOT_STOP_TYPING}: {error}", id.0));
	}
	Ok(step)
}

async fn think<R: Rooms>(env: &Env<'_, R>, id: TurnId, stop: &mut watch::Receiver<bool>) -> Result<Step, Error> {
	// `--deadline` bounds one reply, so every run of this turn shares it,
	// across a think a failure sent back here too.
	let deadline = Duration::from_secs(env.config.deadline_secs);
	// A turn the bot restarted between tries has no memory of its last kind, so
	// the note its ledger row keeps for that run names it.
	let stored = match env.ledger.borrow().phase(id) {
		Some(Phase::Running { note: Some(note), .. }) => FailureKind::of_label(note),
		_ => None,
	};
	let Reply { ends, mut last_kind } = *env.replies.borrow_mut().entry(id).or_insert_with(|| Reply {
		ends: Instant::now() + deadline,
		last_kind: stored,
	});
	let mut unsaved = env.unsaved.borrow_mut().remove(&id);
	loop {
		let phase = env.ledger.borrow().phase(id).cloned();
		let (asked, stored_spent, note, progress) = match phase {
			Some(Phase::Running {
				asked,
				runs: Runs { spent, progress },
				note,
			}) => (asked, spent, note, progress),
			Some(Phase::Sending { .. }) => return Ok(Step::Deliver),
			Some(Phase::Done { .. }) => return Ok(Step::Finished),
			None => return Err(Ledger::invariant("a turn left the ledger while it ran")),
		};
		if let Some(Unsaved { content, parts, cause }) = unsaved.take() {
			return fix_reply(env, id, (content, parts, cause), stop).await;
		}
		// A run still in flight at startup ended with the bot that ran it, and
		// it counts, since the harness may be what ended the bot.
		let spent = match progress {
			Progress::InFlight => stored_spent.saturating_add(1),
			Progress::Ready | Progress::CutOff => stored_spent,
		};
		let resets = reset::asked(&asked);
		// Only while no run of the turn is counted, so a run counted after it
		// started the new conversation keeps it. A first run cut off by a halt,
		// or interrupted by a restart, is not counted yet, so the run that
		// resumes it begins another fresh conversation and the cut-off run's
		// is forgotten.
		if resets && stored_spent == 0 {
			reset::begin(env, id, &asked)?;
		}
		if reset::is_whole(&asked) {
			let part = Part {
				operation: crate::bot::identity::new_action(env.store.root())?,
				text: words::RESET_CONFIRMED.into(),
			};
			return fix_reply(env, id, (Content::Answer, vec![part], None), stop).await;
		}
		if spent >= MAX_RUNS {
			let reason = note.as_deref().unwrap_or("the work was cut off");
			let said = format!("{reason}, after {spent} tries");
			let cause = Cause::decided(last_kind, &said, None);
			return fail_turn(env, id, &cause.room.clone(), Some(cause), stop).await;
		}
		let before = Runs {
			spent: stored_spent,
			progress,
		};
		match attempt(env, id, &asked, (spent, before), ends, stop).await? {
			Run::Answer(text) => {
				env.facts.borrow_mut().answered();
				let parts = answer_parts(env, id, &text, resets)?;
				return fix_reply(env, id, (Content::Answer, parts, None), stop).await;
			}
			Run::Retry(kind) => {
				last_kind = Some(kind);
				env.replies.borrow_mut().insert(id, Reply { ends, last_kind });
				if fault::fails(Fail::RetryWrite) {
					return Err(Error::Storage(StorageError::Io(std::io::Error::from_raw_os_error(5))));
				}
				env.ledger.borrow_mut().retry(env.store, id, kind.label().to_owned())?;
			}
			Run::GiveUp(cause) => {
				return fail_turn(env, id, &cause.room.clone(), Some(cause), stop).await;
			}
			Run::NotStarted => return Ok(Step::Stopped),
			Run::Stopped => {
				// The bot's own stop is not a failed run, so it spends none,
				// and memory keeps that when the write fails.
				let mut ledger = env.ledger.borrow_mut();
				ledger.cut_off(id)?;
				if fault::fails(Fail::CutOffWrite) {
					return Err(Error::Storage(StorageError::Io(std::io::Error::from_raw_os_error(5))));
				}
				ledger.durable(env.store)?;
				return Ok(Step::Stopped);
			}
		}
	}
}

/// The lines an agent's answer becomes, led by the `/reset` confirmation when
/// the turn asked for one.
fn answer_parts<R: Rooms>(env: &Env<'_, R>, id: TurnId, text: &str, resets: bool) -> Result<Vec<Part>, Error> {
	let text = if text.trim() == reply::NO_REPLY {
		if !resets {
			return Ok(Vec::new());
		}
		""
	} else {
		text
	};
	let parts = reply::split(&reset::lead(text, resets));
	if parts.len() == reply::MAX_PARTS && parts.last().is_some_and(|last| last.ends_with(words::CUT_NOTICE)) {
		env.store.log(&format!(
			"turn {}: the answer ran past {} lines and was cut",
			id.0,
			reply::MAX_PARTS
		));
	}
	let key = crate::bot::identity::action_key(env.store.root())?;
	parts
		.into_iter()
		.map(|text| {
			Ok(Part {
				operation: key.mint()?,
				text,
			})
		})
		.collect()
}

/// End the turn with a failure line that says `reason`. This is the one place
/// a turn's failure line is built, and its write is retried like any reply.
async fn fail_turn<R: Rooms>(
	env: &Env<'_, R>,
	id: TurnId,
	reason: &str,
	cause: Option<Cause>,
	stop: &mut watch::Receiver<bool>,
) -> Result<Step, Error> {
	let part = failure_part(env.store, reason)?;
	fix_reply(env, id, (Content::Failure, vec![part], cause), stop).await
}

/// Close the action budget of turn `id` before its reply is written, so no
/// verb can begin an action between the budget and the ledger's `Sending`
/// row, where the serving loop starts settling the turn's actions. A budget
/// that stays open lets a process the agent detached begin one more action,
/// which the loop settles like any other.
fn close_budget<R: Rooms>(env: &Env<'_, R>, id: TurnId) {
	let conversation = match env.ledger.borrow().phase(id) {
		Some(Phase::Running { asked, .. }) => asked.conversation.clone(),
		_ => return,
	};
	if let Err(error) = actions::close(env.store.root(), &conversation) {
		// tolerant: the reply must still go out. A verb that slips through an
		// open budget leaves a claim the loop removes and settles from the
		// operation alone, and the loop's keep or release and the verb's are
		// both idempotent: the session answers kept for an adopted receipt and
		// released for a released one, and a claim removed twice is no error.
		// The budget stays bounded, and the conversation's next turn closes it.
		env.store.log(&format!("turn {}: {error}", id.0));
	}
}

/// Fix a reply the harness already produced in the ledger. A write that can
/// clear with time is retried after a wait and never sends the turn back to
/// the harness. A stop leaves the reply unwritten, and a failure that waiting
/// cannot clear is the caller's. Until the write lands the reply stays
/// [`Unsaved`], so the turn's next think writes it again.
async fn fix_reply<R: Rooms>(
	env: &Env<'_, R>,
	id: TurnId,
	(content, parts, cause): (Content, Vec<Part>, Option<Cause>),
	stop: &mut watch::Receiver<bool>,
) -> Result<Step, Error> {
	env.unsaved.borrow_mut().insert(
		id,
		Unsaved {
			content,
			parts: parts.clone(),
			cause: cause.clone(),
		},
	);
	close_budget(env, id);
	let mut backoff = Backoff::standard();
	let mut failed = false;
	loop {
		let written = if fault::fails(Fail::AnswerWrite) {
			Err(Error::Storage(StorageError::Io(std::io::Error::from_raw_os_error(5))))
		} else if fault::fails(Fail::AnswerRefused) {
			Err(Error::Storage(StorageError::Io(std::io::Error::from_raw_os_error(13))))
		} else {
			env.ledger.borrow_mut().answer(env.store, id, content, parts.clone())
		};
		match written {
			Ok(()) => {
				env.unsaved.borrow_mut().remove(&id);
				if failed {
					env.facts.borrow_mut().recovered(Activity::Saving);
				}
				// Once the reply is saved, so a save that fails does not count
				// the give-up a second time when the turn runs again.
				if let Some(cause) = &cause {
					cause.record(env, id);
				}
				return Ok(Step::Deliver);
			}
			Err(error) if error.is_transient() => {
				failed = true;
				env.store.log(&format!(
					"turn {}: saving the harness's answer failed, {SAVE_RETRIED_WITHOUT_RUNNING}: {error}",
					id.0
				));
				env.facts.borrow_mut().failed(Activity::Saving, &error);
				env.publish();
				if !waited(backoff.next(), stop).await {
					return Ok(Step::Stopped);
				}
			}
			Err(error) => return Err(error),
		}
	}
}

/// Everything one invocation needs, so a failed resume can run again fresh.
struct Inputs<'a> {
	id: TurnId,
	conversation: &'a ConversationId,
	/// The turn's prompt for a run that does or does not resume a session.
	prompt: &'a dyn Fn(bool) -> Result<String, Error>,
	system: &'a str,
	place: Place<'a>,
	state: &'a std::path::Path,
	home: &'a std::path::Path,
	/// When the reply's deadline passes.
	ends: Instant,
}

async fn invoke<R: Rooms>(
	env: &Env<'_, R>,
	inputs: &Inputs<'_>,
	session: Option<&str>,
	stop: &mut watch::Receiver<bool>,
) -> Result<Ran, Error> {
	let prompt = (inputs.prompt)(session.is_some())?;
	let mut invocation = env.harness.invocation(&Turn {
		prompt: &prompt,
		system: inputs.system,
		session,
		workdir: inputs.place.workdir,
		home: inputs.home,
		state: inputs.state,
		model: env.config.model.as_deref(),
		permission: env.config.permission,
	});
	let left = inputs.ends.saturating_duration_since(Instant::now());
	// tolerant: a clock before the epoch leaves the deadline unannounced, and
	// a verb then waits its shortest time.
	let ends = std::time::SystemTime::now()
		.checked_add(left)
		.and_then(|at| at.duration_since(std::time::UNIX_EPOCH).ok());
	invocation
		.env
		.extend(ends.map(|ends| (act::TURN_ENDS.into(), ends.as_millis().to_string().into())));
	invocation.env.extend([
		(act::TURN_BOT.into(), env.store.root().into()),
		(act::TURN_CONVERSATION.into(), inputs.conversation.as_str().into()),
		(act::TURN_ID.into(), inputs.id.0.to_string().into()),
		(home::TURN_HOME.into(), inputs.home.into()),
	]);
	env.store.log(&format!(
		"turn {}: the agent starts with {} ms of the reply's deadline left",
		inputs.id.0,
		left.as_millis()
	));
	runner::run(env.harness, invocation, &inputs.place, left, stop).await
}

/// Record run number `spent` as started on disk, then run the harness once,
/// showing the bot typing meanwhile. The runner fails only when the harness
/// was not given its prompt, so the record is then put back to `before`.
async fn run_once<R: Rooms>(
	env: &Env<'_, R>,
	id: TurnId,
	inputs: &Inputs<'_>,
	session: Option<&str>,
	(spent, before): (u32, Runs),
	stop: &mut watch::Receiver<bool>,
) -> Result<Ran, Error> {
	env.ledger.borrow_mut().start_run(env.store, id, spent)?;
	let invoked = tokio::select! {
		invoked = invoke(env, inputs, session, stop) => invoked,
		never = typing(env, inputs.conversation, id) => match never {},
	};
	if invoked.is_err()
		&& let Err(undo) = env.ledger.borrow_mut().unstart_run(env.store, id, before)
	{
		// tolerant: the run stays recorded as started, so the next attempt
		// counts it. That costs at most one of its tries.
		env.store
			.log(&format!("turn {}: undoing a run that never started: {undo}", id.0));
	}
	invoked
}

/// One run of the harness, within what is left before `ends`. Everything that
/// can fail on storage happens before the run is recorded as started, and a
/// harness that could not be started puts the record back, so only a harness
/// that ran counts against the turn. Keeping the session id afterwards is best
/// effort, since a lost id costs one resume and never a rerun.
async fn attempt<R: Rooms>(
	env: &Env<'_, R>,
	id: TurnId,
	asked: &Asked,
	(spent, before): (u32, Runs),
	ends: Instant,
	stop: &mut watch::Receiver<bool>,
) -> Result<Run, Error> {
	let interrupted = before.progress != Progress::Ready;
	let conversation = &asked.conversation;
	let name = env.harness.name();
	let workdir = env.store.workdir(conversation)?;
	let groups = env.store.groups()?;
	let state = env.store.harness_state(name, conversation);
	let record = store::file_stem(conversation);
	let ring = context::lines(env.store, conversation)?;
	// A `/reset` line has done its work before the run and is not asked.
	let triggers: Vec<_> = asked
		.triggers
		.iter()
		.filter(|trigger| !reset::asks(asked.kind, &trigger.text))
		.cloned()
		.collect();
	let fetched = tokio::select! {
		biased;
		() = stopping(stop) => return Ok(Run::NotStarted),
		fetched = inbox::fetch((env.rooms, env.store), &workdir, id, &triggers, inbox::fetch_ends(ends)) => fetched,
	};
	let listing = home::listing(env.store.root());
	if listing.unnamed > 0 {
		env.store.log(&format!(
			"turn {}: {} memory files have names that are not plain text, so the prompt leaves them out",
			id.0, listing.unnamed
		));
	}
	// Every run after the turn's first is told what the bot's own claims say
	// the earlier runs' actions did, whatever ended them. The claims are read
	// as each run starts, so a run that follows another within the attempt
	// reads what the loop settled meanwhile.
	let turn_prompt = |history: bool| {
		let acted = opens::action::earlier(env.store.root(), id)?;
		let earlier = interrupted || !acted.is_empty();
		Ok(prompt::turn(
			&listing,
			&ring,
			&triggers,
			&fetched,
			earlier.then_some(prompt::Earlier {
				history,
				actions: &acted,
			}),
		))
	};
	let instructions = match &env.config.instructions {
		Some(path) => match config::instructions(path) {
			Ok(text) => Some(text),
			Err(error) => {
				return Ok(Run::GiveUp(Cause::decided(
					None,
					words::INSTRUCTIONS_UNREADABLE,
					Some(&format!("{error}. Fix the file --instructions names")),
				)));
			}
		},
		None => None,
	};
	let home = home::path(env.store.root());
	let system = prompt::system(&prompt::Facts {
		config: env.config,
		home: &home,
		conversation,
		kind: asked.kind,
		instructions: instructions.as_deref(),
	});
	let inputs = Inputs {
		id,
		conversation,
		prompt: &turn_prompt,
		system: &system,
		place: Place {
			workdir: &workdir,
			groups: &groups,
			record: &record,
		},
		state: &state,
		home: &home,
		ends,
	};
	let stored = env.harness_sessions.borrow().get(name, conversation).map(str::to_owned);
	actions::open(env.store.root(), conversation, id)?;
	let tag = format!("turn {}", id.0);
	let (ran, fresh) = run_resuming(env, id, &inputs, stored.as_deref(), (spent, before), stop).await?;
	for note in &ran.notes {
		env.store.log(&format!("{tag}: {note}"));
	}
	keep_session(env, &tag, conversation, &ran, fresh);
	Ok(run_of(env, &tag, ran.finish))
}

/// Run the harness on the stored session, and once more on a new one when
/// that crash proves the stored one unusable. Returns the last run and
/// whether a new session was tried.
///
/// A crash proves the stored session unusable only when the agent never gave
/// a sign that it reached the session. An agent that named it or began work
/// was ended by something else, and the next run resumes it again.
async fn run_resuming<R: Rooms>(
	env: &Env<'_, R>,
	id: TurnId,
	inputs: &Inputs<'_>,
	stored: Option<&str>,
	(spent, before): (u32, Runs),
	stop: &mut watch::Receiver<bool>,
) -> Result<(Ran, bool), Error> {
	let mut ran = run_once(env, id, inputs, stored, (spent, before), stop).await?;
	let tag = format!("turn {}", id.0);
	if let (Some(session), Finish::Failed(FailureKind::Crash, detail), Heard::Silent) = (stored, &ran.finish, ran.heard)
	{
		// The new session is another start, so it is one of the turn's tries.
		if spent.saturating_add(1) < MAX_RUNS {
			env.store.log(&format!(
				"{tag}: resuming session {session} failed ({detail}). Trying once with a new session"
			));
			let second = Runs {
				spent: spent.saturating_add(1),
				progress: Progress::Ready,
			};
			ran = run_once(env, id, inputs, None, (second.spent, second), stop).await?;
		} else {
			env.store.log(&format!(
				"{tag}: resuming session {session} failed ({detail}), and no try is left to start a new one"
			));
		}
		return Ok((ran, true));
	}
	Ok((ran, false))
}

/// Remember the session a run reached, or forget one that was lost or that
/// only a fresh run got past, so it is never given to the harness again.
fn keep_session<R: Rooms>(env: &Env<'_, R>, tag: &str, conversation: &ConversationId, ran: &Ran, fresh: bool) {
	let name = env.harness.name();
	let lost = matches!(ran.finish, Finish::LostSession(_));
	let kept = match &ran.session {
		Some(session) if !lost => env
			.harness_sessions
			.borrow_mut()
			.remember(env.store, name, conversation, session),
		_ if lost || fresh => env.harness_sessions.borrow_mut().forget(env.store, name, conversation),
		_ => Ok(()),
	};
	if let Err(error) = kept {
		// tolerant: the turn's answer stands. The next message starts a new
		// harness session, or resumes a stale one the runner then refuses.
		env.store
			.log(&format!("{tag}: keeping the harness session failed: {error}"));
	}
}

/// What a finished run means for the turn.
fn run_of<R: Rooms>(env: &Env<'_, R>, tag: &str, finish: Finish) -> Run {
	match finish {
		Finish::Cancelled => Run::Stopped,
		Finish::TimedOut => {
			env.store
				.log(&format!("{tag}: timed out after {} seconds", env.config.deadline_secs));
			let said = format!("the agent did not finish within {} seconds", env.config.deadline_secs);
			Run::GiveUp(Cause::decided(
				None,
				&said,
				Some("Raise --deadline if the work needs longer"),
			))
		}
		Finish::LostSession(detail) => {
			env.store.log(&format!("{tag}: {detail}"));
			let said = "the agent lost this conversation's history, so the next message starts a new one";
			Run::GiveUp(Cause::decided(None, said, None))
		}
		Finish::Failed(kind, detail) => {
			env.store.log(&format!("{tag}: {}", kind.logged(&detail)));
			if kind.retryable() {
				Run::Retry(kind)
			} else {
				Run::GiveUp(Cause::failed(kind))
			}
		}
		Finish::Answered(text) if text.trim().is_empty() => {
			env.store.log(&format!("{tag}: the harness answered with nothing"));
			Run::Retry(FailureKind::Crash)
		}
		Finish::Answered(text) => Run::Answer(text.trim_end().to_owned()),
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn a_sign_in_give_up_holds_fixed_words_and_the_next_step_for_the_room_and_the_operator() {
		let cause = Cause::failed(FailureKind::SignIn);
		assert_eq!(cause.room, "the agent refused its sign-in");
		assert_eq!(
			cause.operator,
			"the agent refused its sign-in. Sign the agent in again as the user that runs serve"
		);
	}

	#[test]
	fn a_give_up_the_bot_decided_names_a_step_only_when_one_is_the_operators() {
		let lost = Cause::decided(None, "the agent lost the history", None);
		assert_eq!(lost.operator, lost.room);
		let late = Cause::decided(None, "too slow", Some("Raise --deadline"));
		assert_eq!(late.operator, "too slow. Raise --deadline");
		let crashed = Cause::decided(Some(FailureKind::Crash), "stopped, after 2 tries", None);
		assert!(crashed.operator.starts_with("stopped, after 2 tries. "));
	}
}
