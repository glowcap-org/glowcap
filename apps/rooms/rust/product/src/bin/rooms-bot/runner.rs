//! Run one harness invocation to its end. The runner owns the process: its
//! own group and that group's record, the deadline, the kill, and a bounded
//! tail of stderr. The adapter only says what each stdout line means, and the
//! runner trusts none of it past its own bounds.
//!
//! The harness gets its prompt only after its group is recorded, so a harness
//! started by a bot killed before the record is written reads end of input.
use super::{
	engine::stopping,
	error::Error,
	group::Group,
	harness::{FailureKind, Harness, Invocation, Prepare, Signal},
	reply::MAX_PARTS,
};
use nix::{
	sys::wait::{Id, WaitPidFlag, WaitStatus, waitid},
	unistd::Pid,
};
use rooms_application::room::line::MAX_LINE_BYTES as MAX_REPLY_LINE_BYTES;
use std::{
	os::unix::{fs::symlink, process::CommandExt},
	path::Path,
	process::Stdio,
	time::Duration,
};
use tokio::{
	io::{AsyncBufRead, AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
	process::Command,
	sync::watch,
	time::{Instant, sleep, sleep_until, timeout},
};

/// The longest stdout line the runner reads. A longer line is skipped whole.
const MAX_LINE_BYTES: usize = 4 * 1024 * 1024;
/// How much of the end of stderr a failure keeps.
const STDERR_TAIL_BYTES: usize = 4096;
/// How long a harness that closed stdout may take to exit before it is killed.
const EXIT_GRACE: Duration = Duration::from_secs(5);
const STDERR_GRACE: Duration = Duration::from_secs(2);
/// How long a harness that has given its final answer may keep its output open
/// before its group is ended and the answer is taken, so a process it left
/// behind holding the pipe cannot hold the turn until the deadline.
const ANSWER_GRACE: Duration = Duration::from_secs(3);
/// The most answer text a run keeps. A reply posts at most [`MAX_PARTS`] lines,
/// so twice that leaves room for the breaks the split drops.
pub const MAX_ANSWER_BYTES: usize = 2 * MAX_PARTS * MAX_REPLY_LINE_BYTES;
/// The longest session id the runner accepts from a harness.
pub const MAX_SESSION_BYTES: usize = 128;

#[derive(Debug, PartialEq, Eq)]
pub enum Finish {
	Answered(String),
	Failed(FailureKind, String),
	TimedOut,
	/// The harness was asked to continue one session and continued another,
	/// so it no longer has this conversation's history. The answer is unused.
	LostSession(String),
	/// The bot is shutting down. The turn did not end.
	Cancelled,
}

/// What a run shows about the session it was asked to continue. A failure
/// says nothing about the session unless the process ran without ever giving
/// a sign that it worked.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Heard {
	/// The process never started, so nothing was tried.
	NeverRan,
	/// The process ran and said nothing but failures. An agent does this with
	/// a session it cannot find.
	Silent,
	/// The agent named its session, or began work, so a resume reached it.
	Engaged,
}

#[derive(Debug)]
pub struct Ran {
	pub finish: Finish,
	pub heard: Heard,
	/// What the agent itself said failed, when it said. This is the agent's
	/// own text, so it is cleaned before a person reads it.
	pub cause: Option<String>,
	/// The harness session to resume, when the harness named one.
	pub session: Option<String>,
	/// What the runner refused or cut from the harness's output, for the log.
	pub notes: Vec<String>,
}

/// Where a run happens and where its group is recorded.
pub struct Place<'a> {
	pub workdir: &'a Path,
	pub groups: &'a Path,
	/// The record's file name in `groups`.
	pub record: &'a str,
}

/// Whether a session id is one the bot stores and hands back on a command line.
fn plausible_session(id: &str) -> bool {
	!id.is_empty()
		&& id.len() <= MAX_SESSION_BYTES
		&& !id.starts_with('-')
		&& id.bytes().all(|byte| byte.is_ascii_graphic())
}

/// `text` cut on a character boundary to at most `limit` bytes.
fn cut_to(text: &mut String, limit: usize) -> bool {
	if text.len() <= limit {
		return false;
	}
	text.truncate(text.floor_char_boundary(limit));
	true
}

enum Stop {
	Eof,
	/// The harness gave its final answer and held its output open past
	/// [`ANSWER_GRACE`].
	Answered,
	Deadline,
	Shutdown,
}

/// What the signals of one run add up to.
struct Fold {
	/// Whether any signal other than a failure arrived.
	engaged: bool,
	delta: bool,
	session: Option<String>,
	text: String,
	answer: Option<String>,
	failure: Option<(FailureKind, String)>,
	notes: Vec<String>,
}

impl Fold {
	fn note(&mut self, note: &str) {
		if !self.notes.iter().any(|kept| kept == note) {
			self.notes.push(note.to_owned());
		}
	}

	fn bounded(&mut self, mut text: String) -> String {
		if cut_to(&mut text, MAX_ANSWER_BYTES) {
			self.note("the harness's answer was cut to the size a reply can post");
		}
		text
	}

	fn apply(&mut self, signal: Signal) {
		self.engaged |= match &signal {
			Signal::Failure(..) => false,
			Signal::Session(id) => plausible_session(id),
			Signal::Activity | Signal::Text(_) | Signal::Final(_) => true,
		};
		match signal {
			Signal::Session(id) if plausible_session(&id) => self.session = Some(id),
			Signal::Session(_) => self.note("the harness named a session id the bot does not accept"),
			Signal::Activity => {}
			Signal::Text(text) if self.delta => {
				let room = MAX_ANSWER_BYTES.saturating_sub(self.text.len());
				let mut text = text;
				if cut_to(&mut text, room) {
					self.note("the harness's answer was cut to the size a reply can post");
				}
				self.text.push_str(&text);
			}
			Signal::Text(text) => self.text = self.bounded(text),
			Signal::Final(answer) => self.answer = Some(self.bounded(answer)),
			Signal::Failure(kind, mut detail) => {
				cut_to(&mut detail, STDERR_TAIL_BYTES);
				self.failure.get_or_insert((kind, detail));
			}
		}
	}
}

/// Where reading stdout stands between lines. Bytes accumulate in `line`, so
/// dropping a read between calls loses nothing. `skipping` is set while the
/// rest of an oversized line is discarded, and `skipped` counts those lines.
#[derive(Default)]
struct Lines {
	line: Vec<u8>,
	skipping: bool,
	skipped: usize,
}

impl Lines {
	fn take(&mut self) -> String {
		String::from_utf8_lossy(&std::mem::take(&mut self.line)).into_owned()
	}

	async fn next<R: AsyncBufRead + Unpin>(&mut self, reader: &mut R) -> std::io::Result<Option<String>> {
		loop {
			let available = reader.fill_buf().await?;
			if available.is_empty() {
				if self.line.is_empty() {
					return Ok(None);
				}
				return Ok(Some(self.take()));
			}
			let end = available.iter().position(|byte| *byte == b'\n');
			let count = end.map_or(available.len(), |at| at + 1);
			if !self.skipping {
				if self.line.len() + count > MAX_LINE_BYTES {
					self.skipping = true;
					self.line.clear();
				} else {
					self.line
						.extend_from_slice(&available[..count - usize::from(end.is_some())]);
				}
			}
			reader.consume(count);
			if end.is_some() {
				if std::mem::take(&mut self.skipping) {
					self.skipped += 1;
					continue;
				}
				return Ok(Some(self.take()));
			}
		}
	}
}

/// Do the work an invocation asks for before its process starts.
fn prepare(steps: &[Prepare]) -> Result<(), String> {
	for step in steps {
		match step {
			Prepare::Dir(path) => std::fs::create_dir_all(path)
				.map_err(|error| format!("could not create {}: {error}", path.display()))?,
			Prepare::Link { target, at } => {
				if !target.exists() {
					return Err(format!("{} does not exist", target.display()));
				}
				if std::fs::read_link(at).is_ok_and(|current| current == *target) {
					continue;
				}
				match std::fs::remove_file(at) {
					Ok(()) => {}
					Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
					Err(error) => return Err(format!("could not replace {}: {error}", at.display())),
				}
				symlink(target, at).map_err(|error| format!("could not link {}: {error}", at.display()))?;
			}
			Prepare::File { at, contents } => {
				let (Some(directory), Some(name)) = (at.parent(), at.file_name().and_then(|name| name.to_str())) else {
					return Err(format!("{} is not a file path", at.display()));
				};
				rooms_platform::storage::atomic::replace_at(directory, name, [contents.as_bytes()]).map_err(
					|failure| {
						let (rooms_application::documents::WriteFailure::Unchanged(error)
						| rooms_application::documents::WriteFailure::Indeterminate(error)) = failure;
						format!("could not write {}: {error}", at.display())
					},
				)?;
			}
		}
	}
	Ok(())
}

/// A harness asked to resume one session that reports another has started a
/// new conversation and dropped the old context. The answer is not used.
fn lost_session(asked: Option<&str>, reported: Option<&str>) -> Option<Finish> {
	match (asked, reported) {
		(Some(asked), Some(reported)) if asked != reported => Some(Finish::LostSession(format!(
			"asked to resume session {asked} but the harness continued {reported}"
		))),
		_ => None,
	}
}

fn decide(harness: &dyn Harness, fold: Fold, code: Option<i32>, tail: &str, asked: Option<&str>) -> Finish {
	if let Some(lost) = lost_session(asked, fold.session.as_deref()) {
		return lost;
	}
	if let Some(answer) = fold.answer {
		return Finish::Answered(answer);
	}
	if let Some((kind, detail)) = fold.failure {
		return Finish::Failed(kind, detail);
	}
	if let Some((kind, detail)) = harness.exit(code, tail) {
		return Finish::Failed(kind, detail);
	}
	if code == Some(0) && !fold.text.trim().is_empty() {
		return Finish::Answered(fold.text);
	}
	let detail = match code {
		Some(0) => "the harness ended without an answer".to_owned(),
		Some(code) => format!("the agent exited with status {code} and no answer"),
		None => "the agent was ended by a signal and gave no answer".to_owned(),
	};
	Finish::Failed(FailureKind::Crash, detail)
}

/// Wait up to `grace` for the leader to exit, without reaping it, so its group
/// id stays reserved until the group has been signalled. Returns whether it
/// exited.
async fn exited(leader: u32, grace: Duration) -> bool {
	let Ok(raw) = i32::try_from(leader) else {
		return true;
	};
	let until = Instant::now() + grace;
	loop {
		let flags = WaitPidFlag::WEXITED | WaitPidFlag::WNOHANG | WaitPidFlag::WNOWAIT;
		// Any error means there is nothing left to wait for, such as a leader
		// already reaped.
		if !matches!(waitid(Id::Pid(Pid::from_raw(raw)), flags), Ok(WaitStatus::StillAlive)) {
			return true;
		}
		if Instant::now() >= until {
			return false;
		}
		sleep(Duration::from_millis(20)).await;
	}
}

pub async fn run(
	harness: &dyn Harness,
	invocation: Invocation,
	place: &Place<'_>,
	deadline: Duration,
	shutdown: &mut watch::Receiver<bool>,
) -> Result<Ran, Error> {
	let failed = |detail: String| Ran {
		finish: Finish::Failed(FailureKind::Crash, detail),
		heard: Heard::NeverRan,
		cause: None,
		session: None,
		notes: Vec::new(),
	};
	if *shutdown.borrow() {
		return Ok(Ran {
			finish: Finish::Cancelled,
			heard: Heard::NeverRan,
			cause: None,
			session: None,
			notes: Vec::new(),
		});
	}
	if let Err(reason) = prepare(&invocation.prepare) {
		return Ok(failed(format!(
			"could not prepare {}: {reason}",
			invocation.program.to_string_lossy()
		)));
	}
	let mut command = Command::new(&invocation.program);
	command
		.args(&invocation.args)
		.envs(invocation.env.iter().map(|(key, value)| (key, value)))
		.current_dir(place.workdir)
		.stdin(Stdio::piped())
		.stdout(Stdio::piped())
		.stderr(Stdio::piped())
		.kill_on_drop(true);
	command.as_std_mut().process_group(0);
	let mut child = match command.spawn() {
		Ok(child) => child,
		Err(error) => {
			return Ok(failed(format!(
				"could not start {}: {error}",
				invocation.program.to_string_lossy()
			)));
		}
	};
	let Some(leader) = child.id() else {
		return Ok(failed("the harness exited before it could be watched".into()));
	};
	let stdout = child
		.stdout
		.take()
		.ok_or_else(|| Error::Usage("harness stdout was not piped".into()))?;
	// From here the group is ended when this future ends or is dropped. A
	// group that cannot be recorded is the one error this function returns,
	// and the harness has not been given its prompt by then.
	let group = Group::record(place.groups, place.record, leader)?;
	let stdin = child.stdin.take();
	if let (Some(mut stdin), Some(prompt)) = (stdin, invocation.stdin) {
		tokio::spawn(async move {
			// best-effort: a harness that exits before reading its prompt reports
			// that through its exit status, which the turn already classifies.
			let _ = stdin.write_all(prompt.as_bytes()).await;
		});
	}
	let stderr = child.stderr.take();
	let mut tail = tokio::spawn(async move {
		let mut kept = Vec::new();
		if let Some(mut stderr) = stderr {
			let mut chunk = [0u8; 4096];
			while let Ok(count) = stderr.read(&mut chunk).await {
				if count == 0 {
					break;
				}
				kept.extend_from_slice(&chunk[..count]);
				if kept.len() > STDERR_TAIL_BYTES {
					kept.drain(..kept.len() - STDERR_TAIL_BYTES);
				}
			}
		}
		String::from_utf8_lossy(&kept).into_owned()
	});
	let mut fold = Fold {
		engaged: false,
		delta: harness.text_is_delta(),
		session: None,
		text: String::new(),
		answer: None,
		failure: None,
		notes: Vec::new(),
	};
	let mut stdout = BufReader::new(stdout);
	let asked = invocation.resume;
	let mut lines = Lines::default();
	let ends = Instant::now() + deadline;
	let mut grace: Option<Instant> = None;
	let mut read_error = None;
	let stop = loop {
		tokio::select! {
			biased;
			() = stopping(shutdown) => break Stop::Shutdown,
			() = sleep_until(ends) => break Stop::Deadline,
			() = sleep_until(grace.unwrap_or(ends)), if grace.is_some() => break Stop::Answered,
			read = lines.next(&mut stdout) => match read {
				Ok(Some(text)) => {
					harness.read(&text).into_iter().for_each(|signal| fold.apply(signal));
					if fold.answer.is_some() && grace.is_none() {
						grace = Some(Instant::now() + ANSWER_GRACE);
					}
				}
				Ok(None) => break Stop::Eof,
				Err(error) => {
					read_error = Some(format!("reading the harness's output failed: {error}"));
					break Stop::Eof;
				}
			},
		}
	};
	if lines.skipped > 0 || lines.skipping {
		fold.note("the harness wrote a line longer than the runner reads, and it was skipped");
	}
	if let Some(error) = &read_error {
		fold.note(error);
	}
	if matches!(stop, Stop::Eof) {
		exited(leader, EXIT_GRACE).await;
	}
	// The group is ended before the leader is reaped, so its id cannot have
	// been reused by then.
	if let Err(error) = group.kill() {
		fold.note(&format!("the harness group could not be ended: {error}"));
	}
	let code = match child.wait().await {
		Ok(status) if matches!(stop, Stop::Eof) => status.code(),
		Ok(_) => None,
		Err(error) => {
			fold.note(&format!("waiting for the harness failed: {error}"));
			None
		}
	};
	if let Err(error) = group.end() {
		fold.note(&format!("the harness group record could not be removed: {error}"));
	}
	let tail = match timeout(STDERR_GRACE, &mut tail).await {
		Ok(Ok(text)) => text,
		Ok(Err(_)) | Err(_) => {
			tail.abort();
			String::new()
		}
	};
	let session = fold.session.clone();
	let notes = fold.notes.clone();
	let heard = if fold.engaged { Heard::Engaged } else { Heard::Silent };
	let cause = fold.failure.as_ref().map(|(_, detail)| detail.clone());
	let finish = match stop {
		Stop::Shutdown => Finish::Cancelled,
		Stop::Deadline if fold.answer.is_none() => Finish::TimedOut,
		Stop::Deadline | Stop::Answered => decide(harness, fold, code, &tail, asked.as_deref()),
		Stop::Eof => match decide(harness, fold, code, &tail, asked.as_deref()) {
			Finish::Failed(kind, detail) => match read_error {
				Some(error) => Finish::Failed(kind, format!("{detail} ({error})")),
				None => Finish::Failed(kind, detail),
			},
			finish => finish,
		},
	};
	Ok(Ran {
		finish,
		heard,
		cause,
		session,
		notes,
	})
}

#[cfg(test)]
mod tests;
