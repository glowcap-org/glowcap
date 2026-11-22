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
//!   another base it is refused.
//! - `workspace.json` holds the revision a send is based on and the fence.
//!   A committed line moves the revision. Keeping a line changes the
//!   workspace, as a session's adoption does, so it moves both, and so does
//!   a test that writes the file. A send based past the revision is refused,
//!   and one based before the fence answers a conflict and holds nothing.
//! - `calls.jsonl` logs every send, observe, keep, and release call, in order.
//! - `typing.jsonl` logs every typing notice as its conversation and level.
//! - `events-fault`, while it holds `paused`, `revoked`, `refused`, or
//!   `unreachable`, fails every read that way, and `refused-reads` gets one
//!   line for each read it failed.
//! - `send-faults` holds outcomes to inject, one per line. Each send,
//!   observe, keep, or release call takes the first. `refused`, `unreachable`,
//!   `paused`, and `revoked` fail the call and change nothing. On a send,
//!   `pending` commits the line and answers pending, and `uncertain` commits
//!   it and fails uncertain. `lost` holds no receipt and fails uncertain, as
//!   a send the session never received. `unknown` commits the line and
//!   leaves its receipt unknown, and `vanished` leaves the receipt unknown
//!   and commits nothing. `conflict` changes the workspace first, as another
//!   member's command can, so the send is fenced out and answers a conflict.
//!   On an observe, `pending` answers pending, and `conflict` answers a
//!   conflict, as for a receipt that says its send committed nothing. `ok`
//!   lets a call through.
//! - `files/<token>-<index>` holds the bytes of an attachment a row names. A
//!   fetch copies them.
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
//! for the other person, whose nickname `peer` gives. `revised` marks an edit. `unreadable` stands for a
//! row whose cursor reads and whose event does not.
mod receipts;

use super::{
	Attachment, Base, Batch, Body, Change, ConversationId, Cursor, Echo, Incoming, Kind, Line, Mentions, Outcome,
	Outgoing, Rooms, RoomsError, RoomsErrorKind, Sender,
};
use receipts::{Receipt, Status};
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
	/// The other person's nickname on a direct row.
	peer: Option<String>,
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
			..RoomsError::new(RoomsErrorKind::Unreachable, "the stand-in injected paced")
		});
	}
	let kind = match name {
		"refused" => RoomsErrorKind::Refused,
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
					None => Sender::Peer(row.peer.clone()),
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
			append(&self.directory.join("refused-reads"), &name)?;
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

	/// Take the next injected send outcome.
	fn next_fault(&self) -> Result<Option<String>, RoomsError> {
		let path = self.directory.join("send-faults");
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

	/// Take the next injected fault, failing the call for one that fails it.
	fn fault(&self) -> Result<Option<String>, RoomsError> {
		let fault = self.next_fault()?;
		match fault.as_deref().and_then(failure) {
			Some(error) => Err(error),
			None => Ok(fault),
		}
	}

	/// The receipt of the same operation, or a refusal when it was sent with
	/// another base or line, the way a session refuses a changed intent.
	fn receipt(receipts: &[Receipt], line: &Outgoing<'_>, base: Base) -> Result<Option<usize>, RoomsError> {
		let Some(index) = receipts.iter().position(|held| held.operation == line.operation) else {
			return Ok(None);
		};
		let held = &receipts[index];
		if held.base != base.0 || held.text != line.text || held.conversation != line.conversation.as_str() {
			return Err(RoomsError::new(
				RoomsErrorKind::Refused,
				"effect witness or intent differs",
			));
		}
		Ok(Some(index))
	}

	fn commit(&self, line: &Outgoing<'_>) -> Result<(), RoomsError> {
		append(
			&self.directory.join("outbox.jsonl"),
			&Sent {
				operation: line.operation.to_owned(),
				conversation: line.conversation.as_str().to_owned(),
				text: line.text.to_owned(),
			},
		)?;
		self.moved(false)
	}
}

fn answer(status: Status) -> Outcome {
	match status {
		Status::Committed => Outcome::Committed,
		Status::Pending => Outcome::Pending,
		Status::Unknown => Outcome::Unknown,
		Status::Unsent => Outcome::Conflict,
	}
}

fn uncertain(why: &str) -> RoomsError {
	RoomsError::new(RoomsErrorKind::Uncertain, format!("the stand-in {why}"))
}

impl Rooms for Files {
	async fn events(&self, after: &Cursor, wait: bool) -> Result<Batch, RoomsError> {
		let ends = Instant::now() + WAIT;
		loop {
			let batch = self.read(after)?;
			if !wait || batch.cursor != *after || Instant::now() >= ends {
				return Ok(batch);
			}
			sleep(POLL).await;
		}
	}

	async fn base(&self) -> Result<Base, RoomsError> {
		Ok(Base(self.workspace()?.revision))
	}

	async fn send(&self, line: &Outgoing<'_>, base: Base) -> Result<Outcome, RoomsError> {
		self.log("send", line, base)?;
		let fault = self.fault()?;
		let mut receipts = receipts::read(&self.directory)?;
		if let Some(index) = Self::receipt(&receipts, line, base)? {
			return Ok(answer(receipts[index].status));
		}
		if fault.as_deref() == Some("conflict") {
			self.moved(true)?;
		}
		let workspace = self.workspace()?;
		if base.0 > workspace.revision {
			return Err(RoomsError::new(
				RoomsErrorKind::Refused,
				"the base is past the revision",
			));
		}
		if base.0 < workspace.fence {
			return Ok(Outcome::Conflict);
		}
		let (status, posts) = match fault.as_deref() {
			Some("lost") => return Err(uncertain("lost the send")),
			Some("unknown") => (Status::Unknown, true),
			Some("vanished") => (Status::Unknown, false),
			_ => (Status::Committed, true),
		};
		let receipt = Receipt {
			operation: line.operation.to_owned(),
			base: base.0,
			conversation: line.conversation.as_str().to_owned(),
			text: line.text.to_owned(),
			status,
			kept: false,
		};
		receipts::reserve(&mut receipts, receipt)?;
		receipts::write(&self.directory, &receipts)?;
		if posts {
			self.commit(line)?;
		}
		match fault.as_deref() {
			Some("pending") => Ok(Outcome::Pending),
			Some("uncertain") => Err(uncertain("injected uncertain")),
			_ => Ok(answer(status)),
		}
	}

	async fn observe(&self, line: &Outgoing<'_>, base: Base) -> Result<Outcome, RoomsError> {
		self.log("observe", line, base)?;
		match self.fault()?.as_deref() {
			Some("pending") => return Ok(Outcome::Pending),
			Some("conflict") => return Ok(Outcome::Conflict),
			_ => {}
		}
		let receipts = receipts::read(&self.directory)?;
		Ok(match Self::receipt(&receipts, line, base)? {
			Some(index) => answer(receipts[index].status),
			None => Outcome::Absent,
		})
	}

	async fn keep(&self, line: &Outgoing<'_>, base: Base) -> Result<(), RoomsError> {
		self.log("keep", line, base)?;
		self.fault()?;
		let mut receipts = receipts::read(&self.directory)?;
		let Some(index) = Self::receipt(&receipts, line, base)? else {
			return Ok(());
		};
		if receipts[index].status != Status::Committed {
			return Err(RoomsError::new(
				RoomsErrorKind::Refused,
				"the command has no committed line",
			));
		}
		if receipts[index].kept {
			return Ok(());
		}
		receipts[index].kept = true;
		receipts::write(&self.directory, &receipts)?;
		self.moved(true)
	}

	async fn release(&self, line: &Outgoing<'_>, base: Base) -> Result<(), RoomsError> {
		self.log("release", line, base)?;
		self.fault()?;
		let mut receipts = receipts::read(&self.directory)?;
		let Some(index) = Self::receipt(&receipts, line, base)? else {
			return Ok(());
		};
		if receipts[index].status == Status::Pending {
			return Err(RoomsError::new(
				RoomsErrorKind::Refused,
				"the original executor remains retained; recover it before releasing",
			));
		}
		receipts.remove(index);
		receipts::write(&self.directory, &receipts)
	}

	async fn typing(&self, conversation: &ConversationId, on: bool) -> Result<(), RoomsError> {
		append(
			&self.directory.join("typing.jsonl"),
			&serde_json::json!({"conversation": conversation.as_str(), "on": on}),
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
		let source = self
			.directory
			.join("files")
			.join(format!("{}-{}", attachment.token, attachment.index));
		if destination.exists() {
			return Err(RoomsError::new(RoomsErrorKind::Exists, "the file is already saved"));
		}
		std::fs::copy(&source, destination).map_err(|error| RoomsError::new(RoomsErrorKind::Refused, error))
	}
}

#[cfg(test)]
mod tests;
