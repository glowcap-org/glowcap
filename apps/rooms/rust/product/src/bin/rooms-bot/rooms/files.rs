//! A directory standing in for a session, so process tests can drive the bot
//! through the [`Rooms`] seam, inject every outcome a session can give, and
//! count every send. Only a build with the `test-support` feature has it.
//!
//! - `inbox.jsonl` holds the event rows a test appends. `at` orders them and
//!   gives each its cursor, `e` and `at` in hexadecimal, so cursors do not sort
//!   the way their numbers do. A read returns at most [`BATCH`] events.
//! - `outbox.jsonl` holds every committed line, once per operation. It is
//!   also activity's echo of each line: [`Rooms::echoed`] finds a line there
//!   by its operation, unless `echo-fault` exists, which makes every echo
//!   unknowable, or `restarted` while it holds that word, which makes each
//!   echo read as a restarted session's.
//! - `receipts.json` holds the receipts, as `receipts` describes. An
//!   operation sent again at its base is answered from its receipt, and at
//!   another base it is refused, and a look at it there finds nothing applied.
//! - `workspace.json` holds the revision a send is based on and the fence.
//!   A committed line moves the revision. Keeping a line changes the
//!   workspace, as a session's adoption does, so it moves both, and so does
//!   a test that writes the file. A send based past the revision is refused,
//!   and one based before the fence answers a conflict and holds nothing.
//! - `calls.jsonl` logs every send, observe, keep, and release call, in order.
//! - `typing.jsonl` logs every typing notice as its conversation and level.
//! - `events-fault`, while it holds `paused`, `revoked`, `denied`, or
//!   `unreachable`, fails every read that way, and `failed-reads` gets one
//!   line for each read it failed.
//! - `send-faults` holds outcomes to inject, one per line. Each send,
//!   observe, keep, or release call takes the first. `refused` (the one
//!   request), `denied` (the access), `unreachable`, `paused`, and `revoked`
//!   fail the call and change nothing. The three access states also set
//!   `events-fault`, so reads fail the same way until it is cleared. On a
//!   send, `pending` posts the line and answers pending, and its receipt runs
//!   until the next look finds it committed, and `uncertain` commits it and
//!   fails uncertain. `lost` holds no receipt and fails uncertain, as
//!   a send the session never received. `late` does the same and parks the
//!   send in `late.jsonl`, and the next call that takes `land` commits every
//!   parked send first, as a send still on its way does. `unknown` commits the line and
//!   leaves its receipt unknown, and `vanished` leaves the receipt unknown
//!   and commits nothing. `conflict` changes the workspace first, as another
//!   member's command can, so the send is fenced out and answers a conflict.
//!   On an observe, `pending` answers pending, and `conflict` answers a
//!   conflict, as for a receipt that says its send committed nothing. A
//!   release answers `executor-running`. `ok` lets a call through.
//! - `files/<token>-<index>` holds the bytes of an attachment a row names. A
//!   fetch copies them.
//! - `open-answers` holds how each direct-message open settles when it is
//!   looked at again, one per line: `opened`, `reused`, `unapplied`,
//!   `released`, `pending`, `unknown`, or a failure as in `send-faults`. Each
//!   look takes the first and is logged in `calls.jsonl` as `settle-open`, and
//!   with none left a look is refused.
//! - `release-answers` holds how each request to give an open's receipt back
//!   is answered, one per line: `released`, `executor-running`, or a failure
//!   as in `send-faults`. Each takes the first and is logged as
//!   `release-open`, and with none left it answers released, as the session
//!   answers for a receipt it does not hold.
//! - `action-answers` holds how each agent's action settles when the session
//!   is asked about it, one per line: `gone`, `kept`, `kept-incomplete`, `unapplied`, `released`,
//!   `pending`, `unknown`, or a failure as in `send-faults`. Each look takes
//!   the first and is logged as `settle-action`, and with none left a look is
//!   refused. Giving an action's receipt back takes from `release-answers` and
//!   is logged as `release-action`.
//! - `fetch-faults`: `hang` makes the next fetch of a file never answer.
//!   Each fetch is logged as `fetch`.
//! - `held-actions` and `held-opens` hold the operations of the agent's
//!   actions and of direct-message opens whose receipts keep a place, one per
//!   line. They share the receipts' window, so they count against
//!   `MAX_EFFECTS`, and the list of held receipts names them after the
//!   receipts.json lines that keep a place. A look or release that settles
//!   one drops it.
//! - `held-answers` holds how each list of held receipts is answered, and
//!   `holder-answers` how each ask of whose receipt an operation is, one per
//!   line: a failure as in `send-faults`, `ok` to answer, or for a list
//!   `wait`, which writes `held-asked` and answers once `held-go` exists,
//!   or fails after [`HELD_WAIT`].
//!   Each takes the first, and with none left the list lists and the ask
//!   answers this access.
//!
//! ```text
//! {"at":1,"conversation":"c1","kind":"direct","text":"hi"}
//! {"at":2,"conversation":"r1","kind":"room","sender":"ann","text":"x","mentions":{"member":true}}
//! {"at":3,"conversation":"r1","kind":"room","notice":true}
//! {"at":4,"gap":true}
//! {"at":5,"unavailable":true}
//! {"at":6,"unreadable":true}
//! ```
//!
//! `sender` is `own`, `room`, or a nickname, and a direct row leaves it out
//! for the other person. `revised` marks an edit. `unreadable` stands for a row
//! whose cursor reads and whose event does not.
mod lines;
mod receipts;
mod window;

use super::{
	ActionSettled, Attachment, Base, Batch, Body, Change, ConversationId, Cursor, Echo, Handback, Incoming, Kind, Line,
	Mentions, OpenSettled, Outcome, Outgoing, Rooms, RoomsError, RoomsErrorKind, Sender, Standing, Typing, Wait,
};
use serde::{Deserialize, Serialize};
use std::{
	io::Write,
	path::{Path, PathBuf},
	time::Duration,
};
use tokio::time::{Instant, sleep};

const POLL: Duration = Duration::from_millis(20);
/// How long a waiting read lasts before it returns an empty batch.
const WAIT: Duration = Duration::from_secs(5);
/// How long a `wait` answer to the list of held receipts waits for `held-go`
/// before it fails, so a test that never writes the file ends.
const HELD_WAIT: Duration = Duration::from_secs(30);
/// The most events one read returns.
pub const BATCH: usize = 64;

pub struct Files {
	directory: PathBuf,
}

#[derive(Deserialize)]
struct Row {
	at: u64,
	#[serde(default)]
	gap: bool,
	#[serde(default)]
	unavailable: bool,
	#[serde(default)]
	unreadable: bool,
	#[serde(default)]
	conversation: String,
	kind: Option<Kind>,
	#[serde(default)]
	notice: bool,
	sender: Option<String>,
	#[serde(default)]
	revised: bool,
	#[serde(default)]
	text: String,
	#[serde(default)]
	files: Vec<Attachment>,
	#[serde(default)]
	mentions: Mentions,
}

/// The workspace's revision and the revision its last change was made at.
#[derive(Clone, Copy, Default, Serialize, Deserialize)]
pub struct Workspace {
	pub revision: u64,
	pub fence: u64,
}

#[derive(Serialize, Deserialize)]
struct Sent {
	operation: String,
	conversation: String,
	text: String,
}

#[derive(Serialize)]
struct Call<'a> {
	call: &'a str,
	operation: &'a str,
	conversation: &'a str,
	text: &'a str,
	base: u64,
}

fn unreachable(error: impl ToString) -> RoomsError {
	RoomsError::new(RoomsErrorKind::Unreachable, error)
}

fn failure(name: &str) -> Option<RoomsError> {
	if name == "paced" {
		// Pacing proves nothing was dispatched, and advises a wait.
		return Some(RoomsError {
			retry_after: Some(Duration::from_millis(1)),
			refused_before_dispatch: true,
			..RoomsError::new(RoomsErrorKind::Unreachable, "the stand-in injected paced")
		});
	}
	if name == "too-large" {
		// An admission refusal, such as a request too large for the work
		// allowance, also proves nothing was dispatched.
		return Some(RoomsError {
			refused_before_dispatch: true,
			..RoomsError::new(RoomsErrorKind::Refused, "the stand-in injected too-large")
		});
	}
	let kind = match name {
		"refused" => RoomsErrorKind::Refused,
		"denied" => RoomsErrorKind::Denied,
		"paused" => RoomsErrorKind::Paused,
		"revoked" => RoomsErrorKind::Revoked,
		"unreachable" => RoomsErrorKind::Unreachable,
		_ => return None,
	};
	Some(RoomsError::new(kind, format!("the stand-in injected {name}")))
}

fn rows<T: serde::de::DeserializeOwned>(path: &Path) -> Result<Vec<T>, RoomsError> {
	let text = match std::fs::read_to_string(path) {
		Ok(text) => text,
		Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
		Err(error) => return Err(unreachable(error)),
	};
	// A writer may be mid-append, so an unfinished last line is not a row yet.
	let complete = text.rsplit_once('\n').map_or("", |(complete, _)| complete);
	complete
		.lines()
		.filter(|line| !line.trim().is_empty())
		.map(|line| serde_json::from_str(line).map_err(unreachable))
		.collect()
}

fn append(path: &Path, row: &impl Serialize) -> Result<(), RoomsError> {
	let mut bytes = serde_json::to_vec(row).map_err(unreachable)?;
	bytes.push(b'\n');
	std::fs::OpenOptions::new()
		.create(true)
		.append(true)
		.open(path)
		.and_then(|mut file| file.write_all(&bytes).and_then(|()| file.sync_all()))
		.map_err(unreachable)
}

/// The cursor after the row at `at`.
pub fn cursor(at: u64) -> Cursor {
	Cursor::new(format!("e{at:x}")).unwrap_or_default()
}

fn position(cursor: &Cursor) -> Result<u64, RoomsError> {
	match cursor.as_str() {
		"" => Ok(0),
		text => text
			.strip_prefix('e')
			.and_then(|hex| u64::from_str_radix(hex, 16).ok())
			.ok_or_else(|| RoomsError::new(RoomsErrorKind::Refused, "the stand-in never wrote this cursor")),
	}
}

impl Files {
	pub fn open(directory: &Path) -> Self {
		Self {
			directory: directory.to_owned(),
		}
	}

	fn incoming(row: Row) -> Option<Incoming> {
		let kind = row.kind?;
		let body = if row.notice {
			Body::Other
		} else {
			Body::Line(Line {
				id: format!("l{}", row.at),
				sender: match row.sender.as_deref() {
					Some("own") => Sender::Own,
					Some("room") => Sender::System,
					Some(name) => Sender::Member(name.to_owned()),
					None => Sender::Peer,
				},
				change: if row.revised { Change::Revised } else { Change::Said },
				text: row.text,
				files: row.files,
				mentions: row.mentions,
			})
		};
		Some(Incoming {
			cursor: cursor(row.at),
			conversation: ConversationId::new(row.conversation),
			kind,
			body,
		})
	}

	fn read(&self, after: &Cursor) -> Result<Batch, RoomsError> {
		if let Some(name) = self.events_fault()
			&& let Some(error) = failure(&name)
		{
			append(&self.directory.join("failed-reads"), &name)?;
			return Err(error);
		}
		let from = position(after)?;
		let mut batch = Batch {
			events: Vec::new(),
			cursor: after.clone(),
			gap: false,
			unavailable: false,
			unreadable: 0,
		};
		for row in rows::<Row>(&self.directory.join("inbox.jsonl"))? {
			if row.at <= from {
				continue;
			}
			if batch.events.len() == BATCH {
				break;
			}
			batch.cursor = cursor(row.at);
			batch.gap |= row.gap;
			batch.unavailable |= row.unavailable;
			if row.unreadable {
				batch.unreadable += 1;
				continue;
			}
			batch.events.extend(Self::incoming(row));
		}
		Ok(batch)
	}

	fn events_fault(&self) -> Option<String> {
		let text = std::fs::read_to_string(self.directory.join("events-fault")).ok()?;
		Some(text.trim().to_owned())
	}

	/// Take the next injected send outcome. A fault that is a state of the
	/// access also leaves reads failing that way, as a real session whose
	/// access changed would, until a test clears `events-fault`.
	fn next_fault(&self) -> Result<Option<String>, RoomsError> {
		let fault = self.take("send-faults")?;
		if let Some(name) = fault
			.as_deref()
			.filter(|name| matches!(*name, "paused" | "revoked" | "denied"))
		{
			std::fs::write(self.directory.join("events-fault"), name).map_err(unreachable)?;
		}
		Ok(fault)
	}

	/// Take the first line of the file `name`, or none when it holds none.
	fn take(&self, name: &str) -> Result<Option<String>, RoomsError> {
		let path = self.directory.join(name);
		let text = match std::fs::read_to_string(&path) {
			Ok(text) => text,
			Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
			Err(error) => return Err(unreachable(error)),
		};
		let mut lines = text.lines().filter(|line| !line.trim().is_empty());
		let Some(first) = lines.next() else {
			return Ok(None);
		};
		let rest: String = lines.map(|line| format!("{line}\n")).collect();
		std::fs::write(&path, rest).map_err(unreachable)?;
		Ok(Some(first.trim().to_owned()))
	}

	/// The operations the file `name` (`held-actions` or `held-opens`) says
	/// keep a place.
	fn listed(&self, name: &str) -> Result<Vec<String>, RoomsError> {
		match std::fs::read_to_string(self.directory.join(name)) {
			Ok(text) => Ok(text
				.lines()
				.filter(|line| !line.trim().is_empty())
				.map(str::to_owned)
				.collect()),
			Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
			Err(error) => Err(unreachable(error)),
		}
	}

	/// The operations of the agent's actions and opens, whose receipts keep a
	/// place in the same window as the lines'.
	fn places(&self) -> Result<Vec<String>, RoomsError> {
		let mut places = self.listed("held-actions")?;
		places.extend(self.listed("held-opens")?);
		Ok(places)
	}

	/// Drop `operation` from the file `name`, whose receipt keeps no place now.
	fn free(&self, name: &str, operation: &str) -> Result<(), RoomsError> {
		let rest: String = self
			.listed(name)?
			.into_iter()
			.filter(|held| held != operation)
			.map(|held| format!("{held}\n"))
			.collect();
		std::fs::write(self.directory.join(name), rest).map_err(unreachable)
	}

	fn sent(&self) -> Result<Vec<Sent>, RoomsError> {
		rows(&self.directory.join("outbox.jsonl"))
	}

	fn workspace(&self) -> Result<Workspace, RoomsError> {
		match std::fs::read(self.directory.join("workspace.json")) {
			Ok(bytes) => serde_json::from_slice(&bytes).map_err(unreachable),
			Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Workspace::default()),
			Err(error) => Err(unreachable(error)),
		}
	}

	/// Move the revision, and the fence with it when the workspace changed.
	fn moved(&self, changed: bool) -> Result<(), RoomsError> {
		let mut workspace = self.workspace()?;
		workspace.revision += 1;
		if changed {
			workspace.fence = workspace.revision;
		}
		let staged = self.directory.join("workspace.json.next");
		std::fs::write(&staged, serde_json::to_vec(&workspace).map_err(unreachable)?)
			.and_then(|()| std::fs::rename(&staged, self.directory.join("workspace.json")))
			.map_err(unreachable)
	}

	/// Log a look at an open, which names its peer and has no text.
	fn log_open(
		&self,
		verb: &str,
		operation: &str,
		base: Base,
		introduction: &rooms_services::session::attached::Introduction,
	) -> Result<(), RoomsError> {
		let conversation = ConversationId::new(introduction.peer.as_str());
		let look = Outgoing {
			conversation: &conversation,
			text: "",
			operation,
		};
		self.log(verb, &look, base)
	}

	/// Log a call about the agent's action under `operation`, which names no
	/// conversation or base.
	fn log_action(&self, verb: &str, operation: &str) -> Result<(), RoomsError> {
		let nowhere = ConversationId::new("");
		let look = Outgoing {
			conversation: &nowhere,
			text: "",
			operation,
		};
		self.log(verb, &look, Base(0))
	}

	fn log(&self, call: &str, line: &Outgoing<'_>, base: Base) -> Result<(), RoomsError> {
		append(
			&self.directory.join("calls.jsonl"),
			&Call {
				call,
				operation: line.operation,
				conversation: line.conversation.as_str(),
				text: line.text,
				base: base.0,
			},
		)
	}
}

impl Rooms for Files {
	async fn events(&self, after: &Cursor, wait: Wait) -> Result<Batch, RoomsError> {
		let ends = Instant::now() + WAIT;
		loop {
			let batch = self.read(after)?;
			if wait == Wait::Poll || batch.cursor != *after || Instant::now() >= ends {
				return Ok(batch);
			}
			sleep(POLL).await;
		}
	}

	async fn base(&self) -> Result<Base, RoomsError> {
		Ok(Base(self.workspace()?.revision))
	}

	async fn send(&self, line: &Outgoing<'_>, base: Base) -> Result<Outcome, RoomsError> {
		self.send_line(line, base)
	}

	async fn observe(&self, line: &Outgoing<'_>, base: Base) -> Result<Outcome, RoomsError> {
		self.observe_line(line, base)
	}

	async fn keep(&self, line: &Outgoing<'_>, base: Base) -> Result<(), RoomsError> {
		self.keep_line(line, base)
	}

	async fn release(&self, line: &Outgoing<'_>, base: Base) -> Result<Handback, RoomsError> {
		self.release_line(line, base)
	}

	async fn typing(&self, conversation: &ConversationId, typing: Typing) -> Result<(), RoomsError> {
		append(
			&self.directory.join("typing.jsonl"),
			&serde_json::json!({"conversation": conversation.as_str(), "on": typing == Typing::Show}),
		)
	}

	/// Activity's echo, read from the whole outbox. The stand-in keeps no
	/// cursor for a line it committed, so `after` narrows nothing.
	async fn echoed(&self, line: &Outgoing<'_>, _after: &Cursor) -> Result<Echo, RoomsError> {
		match std::fs::read_to_string(self.directory.join("echo-fault")) {
			Ok(fault) if fault.trim() == "restarted" => return Ok(Echo::Restarted),
			Ok(_) => return Ok(Echo::Unknowable),
			Err(_) => {}
		}
		let posted = self
			.sent()?
			.iter()
			.any(|sent| sent.operation == line.operation && sent.conversation == line.conversation.as_str());
		Ok(if posted { Echo::Found } else { Echo::NotFound })
	}

	async fn fetch(&self, attachment: &Attachment, destination: &Path) -> Result<u64, RoomsError> {
		self.log_action("fetch", &attachment.name)?;
		if self.take("fetch-faults")?.as_deref() == Some("hang") {
			return std::future::pending().await;
		}
		let source = self
			.directory
			.join("files")
			.join(format!("{}-{}", attachment.token, attachment.index));
		if destination.exists() {
			return Err(RoomsError::new(RoomsErrorKind::Exists, "the file is already saved"));
		}
		std::fs::copy(&source, destination).map_err(|error| RoomsError::new(RoomsErrorKind::Refused, error))
	}

	/// By default the stand-in's one access sent everything in it.
	async fn holder(&self, _operation: &str) -> Result<super::Holder, RoomsError> {
		let answer = self.take("holder-answers")?;
		if answer.as_deref() == Some("nobody") {
			return Ok(super::Holder::Nobody);
		}
		if let Some(error) = answer.as_deref().and_then(failure) {
			return Err(error);
		}
		Ok(super::Holder::Mine)
	}

	async fn held(&self) -> Result<Vec<String>, RoomsError> {
		let answer = self.take("held-answers")?;
		if answer.as_deref() == Some("wait") {
			std::fs::write(self.directory.join("held-asked"), "").map_err(unreachable)?;
			let ends = Instant::now() + HELD_WAIT;
			while !self.directory.join("held-go").exists() {
				if Instant::now() >= ends {
					return Err(unreachable("held-go never appeared"));
				}
				sleep(POLL).await;
			}
		}
		if let Some(error) = answer.as_deref().and_then(failure) {
			return Err(error);
		}
		let mut held = window::keeping(&receipts::read(&self.directory)?)?;
		held.extend(self.places()?);
		Ok(held)
	}

	async fn settle_open(
		&self,
		operation: &str,
		base: Base,
		introduction: &rooms_services::session::attached::Introduction,
	) -> Result<OpenSettled, RoomsError> {
		self.log_open("settle-open", operation, base, introduction)?;
		let answer = self.take("open-answers")?;
		if let Some(error) = answer.as_deref().and_then(failure) {
			return Err(error);
		}
		let conversation = format!("direct-{}", introduction.peer);
		let settled = match answer.as_deref() {
			Some("opened") => OpenSettled::Opened(conversation),
			Some("reused") => OpenSettled::Reused(conversation),
			Some("unapplied") => OpenSettled::Unapplied,
			Some("released") => OpenSettled::Released,
			Some("pending") => return Ok(OpenSettled::Pending),
			Some("unknown") => return Ok(OpenSettled::Unknown),
			_ => {
				return Err(RoomsError::new(
					RoomsErrorKind::Refused,
					"the stand-in has no answer for this open",
				));
			}
		};
		self.free("held-opens", operation)?;
		Ok(settled)
	}

	async fn release_open(
		&self,
		operation: &str,
		base: Base,
		introduction: &rooms_services::session::attached::Introduction,
	) -> Result<Handback, RoomsError> {
		self.log_open("release-open", operation, base, introduction)?;
		let answer = self.take("release-answers")?;
		if let Some(error) = answer.as_deref().and_then(failure) {
			return Err(error);
		}
		released(answer.as_deref(), || self.free("held-opens", operation))
	}

	async fn settle_action(&self, operation: &str) -> Result<ActionSettled, RoomsError> {
		self.log_action("settle-action", operation)?;
		let answer = self.take("action-answers")?;
		if let Some(error) = answer.as_deref().and_then(failure) {
			return Err(error);
		}
		let settled = match answer.as_deref() {
			Some("gone") => ActionSettled::Gone,
			Some("kept") => ActionSettled::Kept(Standing::Whole),
			Some("kept-incomplete") => ActionSettled::Kept(Standing::Partial),
			Some("unapplied") => ActionSettled::Unapplied,
			Some("released") => ActionSettled::Released,
			_ => return unsettled_action(answer.as_deref()),
		};
		self.free("held-actions", operation)?;
		Ok(settled)
	}

	async fn release_action(&self, operation: &str) -> Result<Handback, RoomsError> {
		self.log_action("release-action", operation)?;
		let answer = self.take("release-answers")?;
		if let Some(error) = answer.as_deref().and_then(failure) {
			return Err(error);
		}
		released(answer.as_deref(), || self.free("held-actions", operation))
	}
}

/// A release's answer: `executor-running` keeps the receipt, and `released`
/// or no answer gives it back and frees its place, as the session answers
/// for a receipt it holds with no running work or does not hold at all.
fn released(answer: Option<&str>, free: impl FnOnce() -> Result<(), RoomsError>) -> Result<Handback, RoomsError> {
	match answer {
		Some("executor-running") => Ok(Handback::Running),
		Some("released") | None => {
			free()?;
			Ok(Handback::Taken)
		}
		Some(other) => Err(RoomsError::new(
			RoomsErrorKind::Refused,
			format!("the stand-in has no release answer {other}"),
		)),
	}
}

/// An action's look that leaves its receipt where it is.
fn unsettled_action(answer: Option<&str>) -> Result<ActionSettled, RoomsError> {
	match answer {
		Some("pending") => Ok(ActionSettled::Pending),
		Some("unknown") => Ok(ActionSettled::Unknown),
		_ => Err(RoomsError::new(
			RoomsErrorKind::Refused,
			"the stand-in has no answer for this action",
		)),
	}
}

#[cfg(test)]
mod tests;
