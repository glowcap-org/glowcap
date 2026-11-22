//! The thinking stage of a turn: run the harness until it answers, or until
//! the turn has spent its runs, and fix the reply's lines in the ledger. Each
//! step writes the ledger before it acts and reads it to decide what comes
//! next, so a bot restarted at any point resumes here.
//!
//! The harness's effects are not undone by a failed write, so a run's result
//! is held in memory until the ledger takes it. A failed write of the reply is
//! retried with backoff and never runs the harness again while this process
//! lives. A bot that dies before that write lands reruns the turn after a
//! restart, because nothing durable says the harness already answered.
use super::{Backoff, Env, Step, failure_part, operation, reason, reset, stopping, waited};
use crate::bot::{
	act, actions, config, context,
	error::Error,
	fault::{self, Point},
	harness::{FailureKind, Turn},
	home, inbox,
	ledger::{Asked, Content, Ledger, MAX_RUNS, Part, Phase, Progress, Started, TurnId},
	prompt, reply,
	rooms::{ConversationId, Rooms, RoomsError},
	runner::{self, Finish, Heard, Place, Ran},
	status::Activity,
	store,
};
use rooms_application::room::membership::TYPING_RENEW_MS;
use rooms_platform::storage::StorageError;
use std::time::Duration;
use tokio::sync::watch;

/// What one run of the harness amounts to for the ledger.
enum Attempt {
	Answer(String),
	/// The run failed in a way another run may fix.
	Retry(String),
	/// Another run cannot help. The text is the reason to post.
	GiveUp(String),
	Stopped,
}

/// Think, then close the turn's action budget and its typing notice once it
/// stops thinking, so no verb acts for it afterwards. A stopped turn keeps
/// its budget for the run that resumes it, and sends no notice: a halted
/// access would refuse it, and readers clear a notice nobody renews.
pub async fn run<R: Rooms>(env: &Env<'_, R>, id: TurnId, stop: &mut watch::Receiver<bool>) -> Result<Step, Error> {
	let conversation = match env.ledger.borrow().phase(id) {
		Some(Phase::Running { asked, .. }) => Some(asked.conversation.clone()),
		_ => None,
	};
	let step = think(env, id, stop).await?;
	if let Some(conversation) = conversation
		&& !matches!(step, Step::Stopped)
	{
		if let Err(error) = actions::close(env.store.root(), &conversation) {
			// tolerant: the budget stays bounded, and the conversation's next
			// turn closes it again.
			env.store.log(&format!("turn {}: {error}", id.0));
		}
		if let Err(error) = notice(env, &conversation, false).await {
			// tolerant: readers clear the notice once nobody renews it.
			env.store
				.log(&format!("turn {}: could not stop showing typing: {error}", id.0));
		}
	}
	Ok(step)
}

/// Say one typing level. The session paces typing notices, so a level said
/// soon after another may be refused with a short wait, and it is said once
/// more after that wait while the wait is shorter than a renewal.
async fn notice<R: Rooms>(env: &Env<'_, R>, conversation: &ConversationId, on: bool) -> Result<(), RoomsError> {
	match env.rooms.typing(conversation, on).await {
		Err(RoomsError {
			retry_after: Some(wait),
			..
		}) if wait < Duration::from_millis(TYPING_RENEW_MS) => {
			tokio::time::sleep(wait).await;
			env.rooms.typing(conversation, on).await
		}
		said => said,
	}
}

/// Show the bot as typing in `conversation` for as long as this future
/// lives, saying so again every `TYPING_RENEW_MS` because readers clear a
/// notice nobody renews. Each notice costs two snapshot reads and two calls
/// to the session.
async fn typing<R: Rooms>(env: &Env<'_, R>, conversation: &ConversationId, id: TurnId) -> std::convert::Infallible {
	let mut logged = false;
	loop {
		if let Err(error) = notice(env, conversation, true).await
			&& !logged
		{
			// tolerant: a missing notice changes nothing the turn does, the
			// next renewal tries again, and the log holds the first failure.
			env.store.log(&format!("turn {}: could not show typing: {error}", id.0));
			logged = true;
		}
		tokio::time::sleep(Duration::from_millis(TYPING_RENEW_MS)).await;
	}
}

async fn think<R: Rooms>(env: &Env<'_, R>, id: TurnId, stop: &mut watch::Receiver<bool>) -> Result<Step, Error> {
	loop {
		let phase = env.ledger.borrow().phase(id).cloned();
		let (asked, stored_spent, note, progress) = match phase {
			Some(Phase::Running {
				asked,
				spent,
				note,
				progress,
			}) => (asked, spent, note, progress),
			Some(Phase::Sending { .. }) => return Ok(Step::Deliver),
			Some(Phase::Done { .. }) => return Ok(Step::Finished),
			None => return Err(Ledger::invariant("a turn left the ledger while it ran")),
		};
		// A run still in flight at startup ended with the bot that ran it, and
		// it counts, since the harness may be what ended the bot.
		let spent = match progress {
			Progress::InFlight => stored_spent.saturating_add(1),
			Progress::Ready | Progress::CutOff => stored_spent,
		};
		let resets = asked.triggers.iter().any(|trigger| reset::asks(&trigger.text));
		// Only before the turn's first run, so a run that already started the
		// new conversation keeps it.
		if resets && stored_spent == 0 {
			env.sessions
				.borrow_mut()
				.forget(env.store, env.harness.name(), &asked.conversation)?;
			env.store.log(&format!(
				"turn {}: /reset starts a new agent conversation in {}",
				id.0, asked.conversation
			));
		}
		if asked.triggers.iter().all(|trigger| reset::asks(&trigger.text)) {
			let part = Part {
				operation: operation()?,
				text: reset::CONFIRMED.into(),
			};
			return fix_reply(env, id, Content::Answer, vec![part], stop).await;
		}
		if spent >= MAX_RUNS {
			let reason = note.as_deref().unwrap_or("the work was cut off");
			let part = failure_part(&format!("{reason}, after {spent} tries"))?;
			env.ledger
				.borrow_mut()
				.answer(env.store, id, Content::Failure, vec![part])?;
			return Ok(Step::Deliver);
		}
		let before = Started {
			spent: stored_spent,
			progress,
		};
		match attempt(env, id, &asked, spent, before, stop).await? {
			Attempt::Answer(text) => {
				let text = if resets {
					format!("{}\n\n{text}", reset::CONFIRMED)
				} else {
					text
				};
				let parts = reply::split(&text);
				if parts.len() == reply::MAX_PARTS && parts.last().is_some_and(|last| last.ends_with(reply::CUT_NOTICE))
				{
					env.store.log(&format!(
						"turn {}: the answer ran past {} lines and was cut",
						id.0,
						reply::MAX_PARTS
					));
				}
				let parts = parts
					.into_iter()
					.map(|text| {
						Ok(Part {
							operation: operation()?,
							text,
						})
					})
					.collect::<Result<Vec<_>, Error>>()?;
				return fix_reply(env, id, Content::Answer, parts, stop).await;
			}
			Attempt::Retry(note) => env.ledger.borrow_mut().retry(env.store, id, note)?,
			Attempt::GiveUp(reason) => {
				let part = failure_part(&reason)?;
				return fix_reply(env, id, Content::Failure, vec![part], stop).await;
			}
			Attempt::Stopped => {
				// The bot's own stop is not a failed run, so it spends none.
				env.ledger.borrow_mut().cut_off(env.store, id)?;
				return Ok(Step::Stopped);
			}
		}
	}
}

/// Fix a reply the harness already produced in the ledger. A write that can
/// clear with time is retried after a wait and never sends the turn back to
/// the harness. A stop leaves the reply unwritten, and a failure that waiting
/// cannot clear is the caller's.
async fn fix_reply<R: Rooms>(
	env: &Env<'_, R>,
	id: TurnId,
	content: Content,
	parts: Vec<Part>,
	stop: &mut watch::Receiver<bool>,
) -> Result<Step, Error> {
	let mut backoff = Backoff::standard();
	let mut failed = false;
	loop {
		let written = if fault::fails(Point::AnswerWrite) {
			Err(Error::Storage(StorageError::Io(std::io::Error::from_raw_os_error(5))))
		} else {
			env.ledger.borrow_mut().answer(env.store, id, content, parts.clone())
		};
		match written {
			Ok(()) => {
				if failed {
					env.facts.borrow_mut().recovered(Activity::Saving);
				}
				return Ok(Step::Deliver);
			}
			Err(error) if error.is_transient() => {
				failed = true;
				env.store.log(&format!(
					"turn {}: saving the harness's answer failed, trying again without running it: {error}",
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
	conversation: &'a ConversationId,
	prompt: &'a str,
	system: &'a str,
	place: Place<'a>,
	state: &'a std::path::Path,
	home: &'a std::path::Path,
	deadline: Duration,
}

async fn invoke<R: Rooms>(
	env: &Env<'_, R>,
	inputs: &Inputs<'_>,
	session: Option<&str>,
	stop: &mut watch::Receiver<bool>,
) -> Result<Ran, Error> {
	let mut invocation = env.harness.invocation(&Turn {
		prompt: inputs.prompt,
		system: inputs.system,
		session,
		workdir: inputs.place.workdir,
		home: inputs.home,
		state: inputs.state,
		model: env.config.model.as_deref(),
		permission: env.config.permission,
	});
	invocation.env.extend([
		(act::TURN_BOT.into(), env.store.root().into()),
		(act::TURN_CONVERSATION.into(), inputs.conversation.as_str().into()),
		(home::TURN_HOME.into(), inputs.home.into()),
	]);
	runner::run(env.harness, invocation, &inputs.place, inputs.deadline, stop).await
}

/// Record run number `spent` as started, then run the harness once, showing
/// the bot typing meanwhile. The runner fails only when the harness was not
/// given its prompt, so the record is then put back to `before`.
async fn run_once<R: Rooms>(
	env: &Env<'_, R>,
	id: TurnId,
	inputs: &Inputs<'_>,
	session: Option<&str>,
	(spent, before): (u32, Started),
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

/// One run of the harness. Everything that can fail on storage happens before
/// the run is recorded as started, and a harness that could not be started
/// puts the record back, so only a harness that ran counts against the turn.
/// Keeping the session id afterwards is best effort, since a lost id costs one
/// resume and never a rerun.
async fn attempt<R: Rooms>(
	env: &Env<'_, R>,
	id: TurnId,
	asked: &Asked,
	spent: u32,
	before: Started,
	stop: &mut watch::Receiver<bool>,
) -> Result<Attempt, Error> {
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
		.filter(|trigger| !reset::asks(&trigger.text))
		.cloned()
		.collect();
	let fetched = tokio::select! {
		biased;
		() = stopping(stop) => return Ok(Attempt::Stopped),
		fetched = inbox::fetch(env, &workdir, id, &triggers) => fetched,
	};
	let listing = home::listing(env.store.root());
	let turn_prompt = prompt::turn(&listing, &ring, &triggers, &fetched, interrupted);
	let instructions = match &env.config.instructions {
		Some(path) => match config::instructions(path) {
			Ok(text) => Some(text),
			Err(error) => {
				env.store.log(&format!("turn {}: {error}", id.0));
				return Ok(Attempt::GiveUp("the bot's instructions file could not be read".into()));
			}
		},
		None => None,
	};
	let home = home::path(env.store.root());
	let system = prompt::system(&prompt::Facts {
		glowcap: &env.config.glowcap,
		home: &home,
		conversation,
		kind: asked.kind,
		instructions: instructions.as_deref(),
	});
	let inputs = Inputs {
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
		deadline: Duration::from_secs(env.config.deadline_secs),
	};
	let tag = format!("turn {}", id.0);
	let stored = env.sessions.borrow().get(name, conversation).map(str::to_owned);
	let senders = ring.iter().map(|line| line.from.as_deref());
	let senders = senders.chain(triggers.iter().map(|trigger| trigger.from.as_deref()));
	actions::open(env.store.root(), conversation, id, senders)?;
	let mut ran = run_once(env, id, &inputs, stored.as_deref(), (spent, before), stop).await?;
	let mut fresh = false;
	// A crash proves the stored session unusable only when the agent never
	// gave a sign that it reached the session. An agent that named it or began
	// work was ended by something else, and the next run resumes it again.
	if let (Some(session), Finish::Failed(FailureKind::Crash, detail), Heard::Silent) =
		(&stored, &ran.finish, ran.heard)
	{
		fresh = true;
		// The new session is another start, so it is one of the turn's tries.
		if spent.saturating_add(1) < MAX_RUNS {
			env.store.log(&format!(
				"{tag}: resuming session {session} failed ({detail}). Trying once with a new session"
			));
			let second = Started {
				spent: spent.saturating_add(1),
				progress: Progress::Ready,
			};
			ran = run_once(env, id, &inputs, None, (second.spent, second), stop).await?;
		} else {
			env.store.log(&format!(
				"{tag}: resuming session {session} failed ({detail}), and no try is left to start a new one"
			));
		}
	}
	for note in &ran.notes {
		env.store.log(&format!("{tag}: {note}"));
	}
	// A lost session, or a stored one that only a fresh run got past, is
	// never handed to the harness again.
	let lost = matches!(ran.finish, Finish::LostSession(_));
	let kept = match &ran.session {
		Some(session) if !lost => env
			.sessions
			.borrow_mut()
			.remember(env.store, name, conversation, session),
		_ if lost || fresh => env.sessions.borrow_mut().forget(env.store, name, conversation),
		_ => Ok(()),
	};
	if let Err(error) = kept {
		// tolerant: the turn's answer stands. The next message starts a new
		// harness session, or resumes a stale one the runner then refuses.
		env.store
			.log(&format!("{tag}: keeping the harness session failed: {error}"));
	}
	Ok(match ran.finish {
		Finish::Cancelled => Attempt::Stopped,
		Finish::TimedOut => {
			env.store
				.log(&format!("{tag}: timed out after {} seconds", env.config.deadline_secs));
			Attempt::GiveUp(format!(
				"the agent did not finish within {} seconds",
				env.config.deadline_secs
			))
		}
		Finish::LostSession(detail) => {
			env.store.log(&format!("{tag}: {detail}"));
			Attempt::GiveUp("the agent lost this conversation's history, so the next message starts a new one".into())
		}
		Finish::Failed(kind, detail) => {
			env.store.log(&format!("{tag}: {kind:?}: {detail}"));
			let why = reason::of(kind, ran.cause.as_deref(), env.store.root());
			if kind.retryable() {
				Attempt::Retry(why)
			} else {
				Attempt::GiveUp(why)
			}
		}
		Finish::Answered(text) if text.trim().is_empty() => {
			env.store.log(&format!("{tag}: the harness answered with nothing"));
			Attempt::Retry(FailureKind::Crash.label().to_owned())
		}
		Finish::Answered(text) => Attempt::Answer(text.trim_end().to_owned()),
	})
}
