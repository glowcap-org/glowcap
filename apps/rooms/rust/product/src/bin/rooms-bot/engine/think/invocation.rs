//! Prepare and run one fresh or resumed harness invocation for a turn.
use super::*;

/// Everything one invocation needs, so a failed resume can run again fresh.
struct Inputs<'a> {
	scheduled: Option<&'a dyn crate::bot::harness::ScheduledHarness>,
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
	let turn = Turn {
		prompt: &prompt,
		system: inputs.system,
		session,
		workdir: inputs.place.workdir,
		home: inputs.home,
		state: inputs.state,
		model: env.config.model.as_deref(),
		permission: env.config.permission,
	};
	let mut invocation = match inputs.scheduled {
		Some(adapter) => adapter.scheduled_invocation(&turn),
		None => env.harness.invocation(&turn),
	};
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
	let scheduled = env.ledger.borrow().scheduled(id).is_some();
	let invoked = tokio::select! {
		invoked = invoke(env, inputs, session, stop) => invoked,
		never = typing(env, inputs.conversation, id), if !scheduled => match never {},
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
pub(super) async fn attempt<R: Rooms>(
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
	let scheduled = if env.ledger.borrow().scheduled(id).is_some() {
		let Some(adapter) = env.harness.scheduled() else {
			return Ok(Run::GiveUp(Cause::decided(
				None,
				&format!("{name} cannot run a tool-free scheduled check-in"),
				None,
			)));
		};
		Some(adapter)
	} else {
		None
	};
	let workdir = env.store.workdir(conversation)?;
	let groups = env.store.groups()?;
	let state = env.store.harness_state(name, conversation);
	let record = store::file_stem(conversation);
	let ring = if scheduled.is_some() {
		context::check_in(env.store, conversation)?
	} else {
		context::lines(env.store, conversation)?
	};
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
		if let Some(scheduled) = env.ledger.borrow().scheduled(id) {
			return Ok(prompt::check_in(&ring, &scheduled.task));
		}
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
	let system = if scheduled.is_some() {
		let mut system = String::from(
			"You are answering a scheduled check-in in Rooms. Use the supplied conversation context and saved task. Only your final reply is delivered, to the original conversation.",
		);
		if let Some(instructions) = &instructions {
			system.push_str("\n\n");
			system.push_str(instructions);
		}
		system
	} else {
		prompt::system(&prompt::Facts {
			config: env.config,
			home: &home,
			conversation,
			kind: asked.kind,
			instructions: instructions.as_deref(),
		})
	};
	let inputs = Inputs {
		scheduled,
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
	let stored = if scheduled.is_none() {
		actions::open(env.store.root(), conversation, id)?;
		env.harness_sessions.borrow().get(name, conversation).map(str::to_owned)
	} else {
		None
	};
	let tag = format!("turn {}", id.0);
	let (ran, fresh) = run_resuming(env, id, &inputs, stored.as_deref(), (spent, before), stop).await?;
	for note in &ran.notes {
		env.store.log(&format!("{tag}: {note}"));
	}
	if scheduled.is_none() {
		keep_session(env, &tag, conversation, &ran, fresh);
	}
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
