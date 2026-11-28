//! One function per action verb, each returning the JSON line it prints.
use super::{Step, Turn, direct, failure, with_view};
use crate::bot::{
	error::Error,
	opens::action::{self, Label, Place, What},
	request::Request,
	rooms::{ConversationId, captp::Live},
	store, words,
};
use claim::{Report, act, decided, looked_spent};
use rooms_services::session::attached::{EffectStatus, Error as ViewError, Files, Outgoing, Sent};
use serde_json::{Value, json};
use std::path::{Component, Path};
use std::{cell::Cell, future::Future, pin::Pin};

/// With [`BASE`], the earlier write a verb looks at again.
pub const OPERATION: &str = "operation";
pub const BASE: &str = "base";

pub const SAY: &[&str] = &["conversation", "text", direct::DM, OPERATION, BASE];
pub const SEND: &[&str] = &["conversation", "text", "file", direct::DM, OPERATION, BASE];
pub const COMMAND: &[&str] = &[OPERATION, BASE];

/// The operation and base `--operation` and `--base` name together, or none.
/// A look again at an uncertain write needs both.
pub fn resend(request: &Request) -> Result<Option<(String, u64)>, Error> {
	match (request.single(OPERATION)?, request.single(BASE)?) {
		(Some(operation), Some(base)) => Ok(Some((
			operation.to_owned(),
			base.parse::<u64>()
				.map_err(|_| Error::Usage("--base must be a revision number".into()))?,
		))),
		(None, None) => Ok(None),
		_ => Err(Error::Usage("--operation and --base go together".into())),
	}
}

fn settled(operation: &str, base: u64, status: EffectStatus) -> Result<Value, Error> {
	match status {
		EffectStatus::Conflict | EffectStatus::Unsent => {
			Err(failure::with_operation(failure::unapplied(status.wire()), operation))
		}
		EffectStatus::Committed | EffectStatus::Pending | EffectStatus::Unknown => {
			Ok(json!({"ok": true, "operation": operation, "base": base, "status": status.wire()}))
		}
	}
}

fn sent(sent: &Sent) -> Result<Value, Error> {
	settled(&sent.operation, sent.base, sent.status)
}

/// A write whose line posted without its authority is a posted line that
/// cannot be edited or withdrawn, and the output says so and whether the
/// session still holds its receipt. It succeeds, because the line posted and
/// sending it again would post a second one.
fn posted(result: Result<Sent, ViewError>, operation: &str) -> Result<Value, Error> {
	match result {
		Ok(done) => sent(&done),
		Err(ViewError::Unkept {
			operation,
			base,
			cause,
			receipt,
			..
		}) => Ok(json!({
			"ok": true, "operation": operation, "base": base, "status": "committed", "kept": false,
			"receipt": if receipt.released() { "released" } else { "held" }, "reason": cause.to_string(),
		})),
		// A command whose result nothing keeps committed all the same, so
		// sending it again would perform it again.
		Err(ViewError::Forfeited {
			operation,
			base,
			receipt,
		}) => Ok(json!({
			"ok": true, "operation": operation, "base": base, "status": "committed", "kept": false,
			"receipt": if receipt.released() { "released" } else { "held" },
			"reason": "nothing here keeps what this command returned",
		})),
		// Nothing was sent, so there is no operation to look at again.
		Err(cause @ ViewError::Unkeepable { .. }) => Err(failure::unobservable(&cause)),
		Err(cause) => Err(failure::with_operation(failure::call(&cause), operation)),
	}
}

/// What an observation or a command at `base` under `operation` answered.
fn sent_of(operation: &str, base: u64, status: Result<EffectStatus, ViewError>) -> Result<Sent, ViewError> {
	status.map(|status| Sent {
		operation: operation.to_owned(),
		base,
		status,
	})
}

/// A post to a direct conversation `--dm` reached names that conversation
/// and the open that made it, or null when an open one was reused.
fn with_opened(mut line: Value, conversation: &str, opened: Value) -> Value {
	if let Some(object) = line.as_object_mut() {
		object.insert("conversation".into(), json!(conversation));
		object.insert("opened".into(), opened);
	}
	line
}

/// What a verb's printed result says in the log: the status it settled at, or
/// its failure.
fn outcome(result: &Result<Value, Error>) -> String {
	match result {
		Ok(line) => format!("status {}", line["status"].as_str().unwrap_or("unknown")),
		Err(error) => format!("failed: {error}"),
	}
}

/// A post that may go to a conversation other than the turn's, written to
/// the bot's log before it is sent and its outcome after. A turn killed in
/// between leaves the first line, which says the post may have gone out.
struct Posting<'a> {
	turn: &'a Turn,
	log: store::Log,
	operation: String,
}

impl<'a> Posting<'a> {
	fn new(turn: &'a Turn, operation: &str) -> Result<Self, Error> {
		Ok(Self {
			turn,
			log: turn.journal()?,
			operation: operation.to_owned(),
		})
	}

	/// Run `post` into `conversation`. One that stays in the turn's own
	/// conversation is not logged. One elsewhere is refused unless its first
	/// line is written, because an unlogged post could not be told from one
	/// that never went out.
	async fn run(&self, conversation: &str, post: impl Future<Output = Result<Value, Error>>) -> Result<Value, Error> {
		let operation = &self.operation;
		if conversation == self.turn.conversation {
			return post.await;
		}
		self.turn
			.try_log(
				&self.log,
				&format!(
					"is posting to conversation {conversation} under operation {operation}, which may have posted if no outcome line follows"
				),
			)
			.map_err(Error::io("writing the log before a post to another conversation"))?;
		let result = post.await;
		let outcome = outcome(&result);
		self.turn.log(
			&self.log,
			&format!("posted to conversation {conversation} under operation {operation}: {outcome}"),
		);
		result
	}
}

/// How many times a post is tried when the workspace moves under it. The bound
/// is the verb's own: a conflict means another writer is busy in the same
/// session, and a few new tries ride out one burst. After the last, the agent
/// gets the session's answer as it came, the `conflict` failure with its
/// `after-state-change` advice, and decides whether to say it again.
const CONFLICT_TRIES: usize = 3;

/// Run a post that takes its own operation each time, again while the session
/// answers that the workspace moved under it. A conflict committed nothing, so
/// another turn posting at the same moment is never an agent's failure, and a
/// new operation is the retry the session expects, as the bot's own delivery
/// reissues one. A `--dm` open meeting a moved workspace is retried the same
/// way, each try under its own operation and note, and a look again at an
/// uncertain open is made once. Each retry is logged, so a conflict shows in
/// the log and not only in a line posted once.
async fn until_applied<T, Fut: Future<Output = Result<T, Error>>>(
	turn: &Turn,
	mut attempt: impl FnMut() -> Fut,
) -> Result<T, Error> {
	let mut tried = 1;
	loop {
		let result = attempt().await;
		match &result {
			Err(error) if tried < CONFLICT_TRIES && failure::is_conflict(error) => {
				tried += 1;
				turn.log(
					&turn.journal()?,
					&format!(
						"{} under a new operation (try {tried} of {CONFLICT_TRIES})",
						words::CONFLICT_RETRY
					),
				);
			}
			_ => return result,
		}
	}
}

/// Reach the conversation `--dm` names. An open the session did not apply
/// because the workspace moved forgot its note, so another try opens under a
/// new operation. A look again at an earlier open names its own operation and
/// base, so it is made once.
async fn reaching(live: &Live, turn: &Turn, dm: &direct::Ask) -> Result<(String, Value), Error> {
	if dm.looks_again() {
		return direct::reach(live, turn, dm).await;
	}
	until_applied(turn, || direct::reach(live, turn, dm)).await
}

/// What a post to `conversation` answered, with the open that made it when
/// `--dm` reached it. A failure after that open names it, so the agent does
/// not open again.
fn after_reaching(result: Result<Value, Error>, conversation: &str, opened: Option<Value>) -> Result<Value, Error> {
	match opened {
		Some(opened) => result
			.map_err(|error| failure::after_reaching(error, conversation, &opened))
			.map(|line| with_opened(line, conversation, opened)),
		None => result,
	}
}

/// Where a post goes: the conversation `--dm` reached and the open that made
/// it, or `conversation` with no open.
async fn target(
	live: &Live,
	turn: &Turn,
	dm: Option<&direct::Ask>,
	conversation: &str,
) -> Result<(String, Option<Value>), Error> {
	match dm {
		Some(dm) => {
			let (conversation, opened) = reaching(live, turn, dm).await?;
			Ok((conversation, Some(opened)))
		}
		None => Ok((conversation.to_owned(), None)),
	}
}

/// The body of a post: what to send with `data` in `conversation` under
/// `operation`. It takes its data as an argument, so its future borrows only
/// what the call lends it.
type Body<D> =
	dyn for<'x> Fn(&'x Live, &'x str, &'x str, &'x D) -> Pin<Box<dyn Future<Output = Result<Sent, ViewError>> + 'x>>;

/// Spend a place, reach where the post goes, and run `body` there until it
/// applies, each try under an operation and note of its own and logged when
/// it leaves the turn's conversation. `report` prints what it answered.
async fn post<D>(
	turn: &Turn,
	dm: Option<direct::Ask>,
	conversation: &str,
	(what, files): (&What, &Cell<Option<Files>>),
	data: &D,
	body: &Body<D>,
	report: Report,
) -> Result<Value, Error> {
	turn.spend()?;
	with_view(turn, |live| async move {
		let (conversation, opened) = target(&live, turn, dm.as_ref(), conversation).await?;
		let (live, conversation) = (&live, &conversation);
		let result = until_applied(turn, || async move {
			let operation = crate::bot::identity::new_action(&turn.bot)?;
			let posting = act(
				turn,
				live,
				&operation,
				what,
				files,
				body(live, conversation, &operation, data),
				report,
			);
			Posting::new(turn, &operation)?.run(conversation, posting).await
		})
		.await;
		after_reaching(result, conversation, opened)
	})
	.await
}

/// Where a post goes as the agent named it: the member `--dm` names, the
/// conversation `--conversation` names, or the turn's own.
fn place(request: &Request, dm: Option<&direct::Ask>) -> Result<Place, Error> {
	Ok(match (dm, request.single("conversation")?) {
		(Some(dm), _) => Place::Dm(Label::of(dm.peer())),
		(None, Some(conversation)) => Place::Conversation(Label::of(conversation)),
		(None, None) => Place::Here,
	})
}

/// Post a line, in the turn's conversation unless `--conversation` names
/// another or `--dm` a member to reach directly. A line elsewhere is written
/// to the bot's log, and the session's rights decide whether it posts.
pub async fn say(request: &Request, turn: &Turn) -> Result<Value, Error> {
	turn.begin()?;
	let text = text::read(request, turn)
		.await?
		.ok_or_else(|| Error::Usage("say needs --text".into()))?;
	let dm = direct::ask(request)?;
	let conversation = request.single("conversation")?.unwrap_or(&turn.conversation);
	let what = What::Say {
		to: place(request, dm.as_ref())?,
	};
	post(
		turn,
		dm,
		conversation,
		(&what, &Cell::new(None)),
		&text,
		&|live, conversation, operation, text| Box::pin(live.view.say(operation, conversation, text)),
		posted,
	)
	.await
}

/// Send files from the turn's own working directory to the turn's
/// conversation unless `--conversation` names another, or to the member `--dm`
/// names. A send elsewhere is written to the bot's log, and the session's
/// rights decide whether it posts.
pub async fn send(request: &Request, turn: &Turn) -> Result<Value, Error> {
	let conversation = request.single("conversation")?.unwrap_or(&turn.conversation);
	let dm = direct::ask(request)?;
	turn.begin()?;
	let caption = text::read(request, turn).await?.unwrap_or_default();
	let work = store::work_dir(
		&store::directory(&turn.bot)?,
		&ConversationId::new(turn.conversation.as_str()),
	);
	let files = request
		.named
		.get("file")
		.map(Vec::as_slice)
		.unwrap_or_default()
		.iter()
		.map(|path| confined(&work, Path::new(path)))
		.collect::<Result<Vec<Outgoing>, _>>()?;
	if files.is_empty() {
		return Err(Error::Usage("send needs at least one --file".into()));
	}
	// The files stay open and are read at the offsets the session asks for, so
	// another try reads them from the start. They stay open until the verb
	// exits, which is after the wait for the room to hold them.
	let standing = Cell::new(None);
	let what = What::Send {
		to: place(request, dm.as_ref())?,
		files: u32::try_from(files.len()).unwrap_or(u32::MAX),
	};
	let line = post(
		turn,
		dm,
		conversation,
		(&what, &standing),
		&(caption, files, turn.budget, &standing),
		&|live, conversation, operation, (caption, files, budget, standing)| {
			Box::pin(async move {
				// The room gets what the budget leaves when the call starts.
				let uploaded = live
					.view
					.send_files(operation, conversation, caption, files, budget.main_ms())
					.await
					.inspect_err(|error| {
						// A post that committed and could not be kept still read
						// how its files stand.
						if let ViewError::Unkept { files: Some(read), .. } = error {
							standing.set(Some(read.clone()));
						}
					})?;
				standing.set(Some(uploaded.files));
				Ok(uploaded.sent)
			})
		},
		|result, operation| match result {
			// No verb looks at a send again, so an uncertain one names no
			// operation or base to check. It must not be sent again.
			Err(cause @ ViewError::Uncertain { .. }) => Err(failure::unobservable(&cause)),
			result => posted(result, operation),
		},
	)
	.await?;
	Ok(with_files(line, standing.take()))
}

/// Say how the files of a `send` stand: that they `complete` the post, that
/// the room stopped taking them and `incomplete` is for the `reason`, or that
/// the wait ended before the session reported the post, so the line may or
/// may not be posted, and the files stop when this verb exits.
fn with_files(mut line: Value, files: Option<Files>) -> Value {
	let Some(object) = line.as_object_mut() else {
		return line;
	};
	// A line that already gives a reason (a post whose line could not be kept)
	// keeps it, and this one follows.
	let mut say = |files: &str, reason: Option<String>| {
		object.insert("files".into(), json!(files));
		if let Some(reason) = reason {
			let reason = match object.get("reason").and_then(Value::as_str) {
				Some(first) => format!("{first}; the files: {reason}"),
				None => reason,
			};
			object.insert("reason".into(), json!(reason));
		}
	};
	match files {
		Some(Files::Complete) => say("complete", None),
		Some(Files::Incomplete(reason)) => say("incomplete", Some(reason)),
		Some(Files::Unfinished) => say(
			"unfinished",
			Some(
				"the session had not reported the post when the wait ended: the line may or may not be posted, and the files stop when this command exits"
					.into(),
			),
		),
		None => {}
	}
	line
}

/// Open a file `send` may post: a regular file beneath the turn's working
/// directory, reached one directory at a time without following a link. The
/// harness runs these verbs, so this keeps the session link, the bot's state,
/// and the rest of the machine out of a room. Each step opens from the
/// directory the step before it opened, so a link swapped in during the walk
/// is refused, never followed.
fn confined(work: &Path, path: &Path) -> Result<Outgoing, Error> {
	use nix::{fcntl::OFlag, sys::stat::Mode};
	let outside = || {
		Error::Usage(format!(
			"send posts regular files from inside {} only, reached without links",
			work.display()
		))
	};
	let absolute = std::path::absolute(path).map_err(Error::io("resolving a file path"))?;
	let mut parts = Vec::new();
	for component in absolute.strip_prefix(work).map_err(|_| outside())?.components() {
		match component {
			Component::Normal(part) => parts.push(part),
			Component::CurDir => {}
			_ => return Err(outside()),
		}
	}
	let (last, directories) = parts.split_last().ok_or_else(outside)?;
	let name = last.to_str().ok_or_else(outside)?;
	let step = OFlag::O_RDONLY | OFlag::O_CLOEXEC | OFlag::O_NOFOLLOW;
	let directory = step | OFlag::O_DIRECTORY;
	let mut held = nix::fcntl::open(work, directory, Mode::empty()).map_err(|_| outside())?;
	for part in directories {
		held = nix::fcntl::openat(&held, *part, directory, Mode::empty()).map_err(|_| outside())?;
	}
	let file = nix::fcntl::openat(&held, *last, step | OFlag::O_NONBLOCK, Mode::empty()).map_err(|_| outside())?;
	let file = std::fs::File::from(file);
	match file.metadata() {
		Ok(metadata) if metadata.is_file() => Ok(Outgoing::new(name, file)),
		_ => Err(outside()),
	}
}

/// What one `command` asks of the session.
enum Call {
	/// Look again at an earlier command under its operation and base.
	Look(String, u64),
	/// Run a new command, under an operation of its own on each try.
	New,
}

/// Run a session command, or look again at an earlier one named by
/// `--operation` and `--base`, and print what the session settled.
pub async fn command(request: &Request, turn: &Turn) -> Result<Value, Error> {
	let Some((name, arguments)) = request.arguments.split_first() else {
		return Err(Error::Usage("command needs the name of a session command".into()));
	};
	// A look at an earlier command acts on nothing. A new one may post or
	// change anything the access allows, so it takes a place and is logged.
	turn.begin()?;
	let call = match resend(request)? {
		Some((operation, base)) => Call::Look(operation, base),
		None => {
			turn.spend()?;
			Call::New
		}
	};
	// A posting command's line is kept, or its receipt released, and a command
	// whose returned capability nothing here keeps is refused before it is
	// sent, so a command that settles in the turn leaves no receipt holding
	// one of the session's places.
	with_view(turn, |live| async move {
		match call {
			Call::Look(operation, base) => {
				// Only the turn that claims an action settles it while the turn
				// is open. Any other look only reads, because the serving loop
				// settles every action no open turn claims.
				let claimed = action::claimed(&store::directory(&turn.bot)?, &operation, turn.id)?;
				let observed = turn.budget.within(Step::Call, async {
					match live.view.observe(&operation, base, name, arguments).await {
						Ok(EffectStatus::Committed) if claimed.is_some() => live
							.view
							.keep_command(&operation, base, name, arguments)
							.await
							.map(|()| EffectStatus::Committed),
						other => other,
					}
				});
				let result = observed.await.map(|status| sent_of(&operation, base, status));
				if let Some(what) = claimed {
					return decided(turn, &live, &operation, &what, &Cell::new(None), result, posted).await;
				}
				match result {
					Some(result) => posted(result, &operation),
					None => Ok(looked_spent(&What::Command { name: Label::of(name) })),
				}
			}
			Call::New => {
				let log = turn.journal()?;
				let live = &live;
				let what = What::Command { name: Label::of(name) };
				let what = &what;
				until_applied(turn, || async {
					let operation = crate::bot::identity::new_action(&turn.bot)?;
					// A command may post to any conversation the access reaches, so
					// it is refused unless its first line is written, as a post
					// elsewhere is, and its outcome follows.
					turn.try_log(&log, &words::command_running(name, &operation))
						.map_err(Error::io(words::COMMAND_LOG_FAILED))?;
					let result = async {
						let base = turn
							.budget
							.within(Step::Call, live.view.revision())
							.await
							.ok_or_else(failure::nothing_sent)?
							.map_err(|cause| failure::call(&cause))?;
						let call = async {
							sent_of(
								&operation,
								base,
								live.view.command(&operation, base, name, arguments).await,
							)
						};
						act(turn, live, &operation, what, &Cell::new(None), call, posted).await
					}
					.await;
					turn.log(&log, &words::command_ran(name, &operation, &outcome(&result)));
					result
				})
				.await
			}
		}
	})
	.await
}

/// Join the one listing this conversation's held directory returns.
pub async fn join(request: &Request, turn: &Turn) -> Result<Value, Error> {
	let room = request
		.single("room")?
		.filter(|name| !name.is_empty())
		.ok_or_else(|| Error::Usage("join requires --room NAME".into()))?;
	if !request.arguments.is_empty() {
		return Err(Error::Usage("join takes only --room NAME".into()));
	}
	turn.begin()?;
	turn.require_running()?;
	turn.spend()?;
	with_view(turn, |live| async move {
		let id = turn.budget.within(Step::Call, live.view.join_listed(&turn.conversation, room)).await
			.ok_or_else(||Error::Usage("the join did not confirm a seat before the turn deadline; repeating the same listing reuses its conversation".into()))?
			.map_err(|cause| failure::call(&cause))?;
		Ok(json!({"ok":true, "status":"joined", "conversation":id, "room":room}))
	}).await
}

/// Print the workspace's revision and intent, as the session holds them now.
pub async fn workspace(turn: &Turn) -> Result<Value, Error> {
	turn.begin()?;
	with_view(turn, |live| async move {
		let snapshot = turn
			.budget
			.within(Step::Call, live.view.snapshot())
			.await
			.ok_or_else(failure::nothing_sent)?
			.map_err(|cause| failure::call(&cause))?;
		let workspace =
			serde_json::to_value(&snapshot.intent).map_err(|cause| Error::state("the workspace snapshot", cause))?;
		Ok(json!({"ok": true, "revision": snapshot.revision.to_string(), "workspace": workspace}))
	})
	.await
}

/// A read scoped to the actual running turn, irrespective of its agent's prompt.
pub async fn members(turn: &Turn) -> Result<Value, Error> {
	turn.begin()?;
	turn.require_running()?;
	with_view(turn, |live| async move {
		let members = turn
			.budget
			.within(Step::Call, live.view.room_members(&turn.conversation))
			.await
			.ok_or_else(failure::nothing_sent)?
			.map_err(|cause| failure::call(&cause))?;
		Ok(json!({"ok": true, "members": members}))
	})
	.await
}

mod claim;
#[cfg(test)]
mod tests;
mod text;

/// List what this turn did and how each action ended, from the bot's own
/// record of it and nothing the session says, so it answers when the session
/// does not. It sends nothing and takes no place.
pub fn actions(turn: &Turn) -> Result<Value, Error> {
	let done = action::earlier(&store::directory(&turn.bot)?, turn.id)?;
	Ok(json!({"ok": true, "actions": done.iter().map(action::Action::listing).collect::<Vec<_>>()}))
}
