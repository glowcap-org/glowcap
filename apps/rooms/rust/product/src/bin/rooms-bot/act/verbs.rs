//! One function per action verb, each returning the JSON line it prints.
use super::{Turn, failure, with_view};
use crate::bot::{engine, error::Error, request::Request, rooms::ConversationId, store};
use rooms_services::session::attached::{EffectStatus, Error as ViewError, Outgoing, Sent};
use serde_json::{Value, json};
use std::io::Read;
use std::path::{Component, Path};

pub const SAY: &[&str] = &["conversation", "text"];
pub const SEND: &[&str] = &["text", "file"];
pub const COMMAND: &[&str] = &["operation", "base"];

/// The most bytes `--text -` reads from standard input, one line's limit.
const MAX_TEXT_BYTES: usize = rooms_application::room::line::MAX_LINE_BYTES;

/// `--text`, read from standard input when its value is `-`.
fn text(request: &Request) -> Result<Option<String>, Error> {
	match request.single("text")? {
		Some("-") => {
			let mut bytes = Vec::new();
			std::io::stdin()
				.take(MAX_TEXT_BYTES as u64 + 1)
				.read_to_end(&mut bytes)
				.map_err(Error::io("reading --text from standard input"))?;
			if bytes.len() > MAX_TEXT_BYTES {
				return Err(Error::Usage(format!(
					"--text - read more than the {MAX_TEXT_BYTES} bytes a line holds"
				)));
			}
			let text =
				String::from_utf8(bytes).map_err(|_| Error::Usage("--text - read text that is not UTF-8".into()))?;
			Ok(Some(text.strip_suffix('\n').map(str::to_owned).unwrap_or(text)))
		}
		other => Ok(other.map(str::to_owned)),
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
			released,
		}) => Ok(json!({
			"ok": true, "operation": operation, "base": base, "status": "committed", "kept": false,
			"receipt": if released { "released" } else { "held" }, "reason": cause.to_string(),
		})),
		Err(cause) => Err(failure::with_operation(failure::call(&cause), operation)),
	}
}

/// Post a line, in the turn's conversation unless `--conversation` names
/// another. A line elsewhere is written to the bot's log, and the session's
/// rights decide whether it posts.
pub async fn say(request: &Request, turn: &Turn) -> Result<Value, Error> {
	let text = text(request)?.ok_or_else(|| Error::Usage("say needs --text".into()))?;
	let conversation = request.single("conversation")?.unwrap_or(&turn.conversation);
	turn.spend()?;
	let operation = engine::operation()?;
	if conversation != turn.conversation {
		store::Log::in_directory(&store::directory(&turn.bot)?).line(&format!(
			"a turn in conversation {} posted to conversation {conversation} under operation {operation}",
			turn.conversation
		));
	}
	with_view(turn, |live| async move {
		posted(live.view.say(&operation, conversation, &text).await, &operation)
	})
	.await
}

/// Send files from the turn's own working directory to the turn's
/// conversation.
pub async fn send(request: &Request, turn: &Turn) -> Result<Value, Error> {
	let conversation = turn.conversation.as_str();
	let caption = text(request)?.unwrap_or_default();
	let work = store::work_dir(&store::directory(&turn.bot)?, &ConversationId::new(conversation));
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
	turn.spend()?;
	let operation = engine::operation()?;
	with_view(turn, |live| async move {
		match live.view.send_files(&operation, conversation, &caption, &files).await {
			// No verb looks at a send again, so an uncertain one names no
			// operation or base to check. It must not be sent again.
			Err(cause @ ViewError::Uncertain { .. }) => Err(failure::unobservable(&cause)),
			result => posted(result, &operation),
		}
	})
	.await
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
	/// Run a new command under this operation.
	New(String),
}

pub async fn command(request: &Request, turn: &Turn) -> Result<Value, Error> {
	let Some((name, arguments)) = request.arguments.split_first() else {
		return Err(Error::Usage("command needs the name of a session command".into()));
	};
	// A look at an earlier command acts on nothing. A new one may post or
	// change anything the access allows, so it takes a place and is logged.
	let call = match (request.single("operation")?, request.single("base")?) {
		(Some(operation), Some(base)) => {
			let base = base
				.parse::<u64>()
				.map_err(|_| Error::Usage("--base must be a revision number".into()))?;
			Call::Look(operation.to_owned(), base)
		}
		(None, None) => {
			turn.spend()?;
			let operation = engine::operation()?;
			store::Log::in_directory(&store::directory(&turn.bot)?).line(&format!(
				"a turn in conversation {} ran session command {name} under operation {operation}",
				turn.conversation
			));
			Call::New(operation)
		}
		_ => return Err(Error::Usage("--operation and --base go together".into())),
	};
	// A posting command's line is kept, or its receipt released, so no turn
	// leaves receipts behind to fill the session's places.
	with_view(turn, |live| async move {
		match call {
			Call::Look(operation, base) => {
				let status = match live.view.observe(&operation, base, name, arguments).await {
					Ok(EffectStatus::Committed) => live
						.view
						.keep_command(&operation, base, name, arguments)
						.await
						.map(|()| EffectStatus::Committed),
					other => other,
				};
				let sent = status.map(|status| Sent {
					operation: operation.clone(),
					base,
					status,
				});
				posted(sent, &operation)
			}
			Call::New(operation) => {
				let base = live.view.revision().await.map_err(|cause| failure::call(&cause))?;
				let status = live.view.command(&operation, base, name, arguments).await;
				let sent = status.map(|status| Sent {
					operation: operation.clone(),
					base,
					status,
				});
				posted(sent, &operation)
			}
		}
	})
	.await
}

pub async fn workspace(turn: &Turn) -> Result<Value, Error> {
	with_view(turn, |live| async move {
		let snapshot = live.view.snapshot().await.map_err(|cause| failure::call(&cause))?;
		let workspace =
			serde_json::to_value(&snapshot.intent).map_err(|cause| Error::state("the workspace snapshot", cause))?;
		Ok(json!({"ok": true, "revision": snapshot.revision.to_string(), "workspace": workspace}))
	})
	.await
}

#[cfg(test)]
mod tests {
	use super::*;
	use rooms_testing::scratch::Scratch;

	#[test]
	fn send_opens_only_regular_files_beneath_the_work_directories_without_links() {
		let scratch = Scratch::create("bot-send-confined");
		let work = scratch.join("work");
		std::fs::create_dir_all(work.join("one/inbox")).unwrap();
		std::fs::write(work.join("one/inbox/kept.txt"), "kept").unwrap();
		std::fs::write(scratch.join("session.link"), "secret").unwrap();
		std::os::unix::fs::symlink(scratch.join("session.link"), work.join("one/link.txt")).unwrap();
		std::os::unix::fs::symlink(&*scratch, work.join("one/up")).unwrap();
		assert!(confined(&work, &work.join("one/inbox/kept.txt")).is_ok());
		assert!(confined(&work, &work.join("one/./inbox/kept.txt")).is_ok());
		for refused in [
			scratch.join("session.link"),
			work.join("one/link.txt"),
			work.join("one/up/session.link"),
			work.join("one/../../session.link"),
			work.join("one/inbox"),
			work.clone(),
		] {
			assert!(confined(&work, &refused).is_err(), "{}", refused.display());
		}
	}
}
