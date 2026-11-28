//! A reminder binds a single text post to the grant and custody coordinates
//! of the turn that requested it. The bot's serve lease admits one timer
//! worker. Turn processes share a separate short transaction lock with it.
mod delivery;
mod schedule;

use super::{error::Error, stamp, store};
use rooms_application::{content::session::workspace::Conversation, fields::lower_hex};
use rooms_platform::storage::{Directory, atomic};
use rooms_services::session::attached::Snapshot;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
	path::Path,
	time::{Duration, SystemTime, UNIX_EPOCH},
};

pub use delivery::{access_lost, run, settle_receipts};
pub use schedule::{Repeat, When};
use tokio::sync::oneshot;

const DIRECTORY: &str = "reminders";
const FILE: &str = "schedules.json";
const MAX_BYTES: usize = 2 * 1024 * 1024;
const HORIZON: u64 = 30 * 86_400;
const OVERDUE: u64 = 86_400;
const RETENTION: u64 = 7 * 86_400;
pub(super) const MAX_ACTIVE: usize = 64;
const MAX_HERE: usize = 8;
const MAX_ROWS: usize = 256;
pub const PREFIX: &str = "[Reminder] ";
pub const CHECK_IN_PREFIX: &str = "[Check-in] ";

pub fn passive(line: &str) -> bool {
	line.starts_with(PREFIX) || line.starts_with(CHECK_IN_PREFIX)
}

pub fn now() -> u64 {
	SystemTime::now()
		.duration_since(UNIX_EPOCH)
		.map_or(0, |duration| duration.as_secs())
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Scope {
	kind: crate::bot::rooms::Kind,
	grant: String,
	conversation: String,
	target: String,
}

impl Scope {
	pub fn kind(&self) -> crate::bot::rooms::Kind {
		self.kind
	}

	pub fn conversation(&self) -> &str {
		&self.conversation
	}

	pub fn matches(&self, grant: &str, snapshot: &Snapshot) -> bool {
		Self::held(grant, self.conversation(), snapshot).as_ref() == Some(self)
	}

	pub fn held(grant: &str, conversation: &str, view: &Snapshot) -> Option<Self> {
		let row = view
			.intent
			.conversations
			.as_slice()
			.iter()
			.find(|row| row.id().text().as_str() == Some(conversation))?;
		let (kind, directory, target) = match row {
			Conversation::Room(room) => (
				crate::bot::rooms::Kind::Room,
				&room.directory,
				json!([
					"room",
					room.source,
					room.inbox,
					room.access,
					room.accepted,
					room.public_entry,
					room.publication,
					room.seat?
				]),
			),
			Conversation::Direct(dm) => (
				crate::bot::rooms::Kind::Direct,
				&dm.directory,
				json!(["direct", dm.peer, dm.source, dm.introduction, dm.installed_access()?]),
			),
		};
		let directory = view
			.intent
			.directories
			.as_slice()
			.iter()
			.find(|row| &row.id == directory)?;
		let target = json!([directory.id, directory.access, directory.source, target]);
		Some(Self {
			kind,
			grant: grant.into(),
			conversation: conversation.into(),
			target: lower_hex(&Sha256::digest(target.to_string().as_bytes())),
		})
	}
}

/// Receives its acknowledgement only after the turn ledger persisted the admission.
pub struct CheckIn {
	pub scope: Scope,
	pub operation: String,
	pub task: String,
	pub reply: oneshot::Sender<Admission>,
}

pub enum Admission {
	Admitted,
	HourlyLimit { until: u64, limit: u32 },
	Busy,
	Refused,
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Kind {
	Reminder,
	CheckIn,
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
enum Outcome {
	Delivered,
	Admitted,
	Cancelled,
	Expired,
	TargetChanged,
	AccessLost,
	Unconfirmed,
	Refused,
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
enum Delay {
	HourlyLimit { limit: u32 },
	WorkerBusy,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
enum State {
	Scheduled,
	Deferred {
		retry_at: u64,
		reason: Delay,
	},
	Admitting,
	// Persisted before dispatch. Recovery may observe this operation, never
	// issue another post on the assumption that a receipt does not exist.
	Sending {
		base: u64,
	},
	Between {
		base: u64,
	},
	Finished {
		outcome: Outcome,
		at: u64,
		release: Option<u64>,
	},
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
struct Reminder {
	id: String,
	kind: Kind,
	scope: Scope,
	when: When,
	repeat: Option<Repeat>,
	occurrence: u32,
	delivered: u32,
	admitted: u32,
	skipped: u32,
	due: u64,
	text: String,
	operation: String,
	state: State,
}

impl Reminder {
	fn valid(&self) -> bool {
		let count = self.repeat.map_or(1, |r| r.count);
		let hex = |s: &str, n| s.len() == n && s.bytes().all(|b| b.is_ascii_hexdigit());
		self.repeat
			.is_none_or(|r| (60..=HORIZON).contains(&r.every_seconds) && (2..=32).contains(&r.count))
			&& (1..=count).contains(&self.occurrence)
			&& self.delivered <= self.occurrence
			&& self.admitted <= self.occurrence
			&& self.skipped <= self.occurrence
			&& self.scope.kind != crate::bot::rooms::Kind::Other
			&& valid_id(&self.id).is_ok()
			&& valid_text(&self.text)
			&& self.due <= 253_402_300_799
			&& self.operation.strip_prefix("reminder-").is_some_and(|id| hex(id, 32))
			&& hex(&self.scope.grant, 64)
			&& hex(&self.scope.target, 64)
			&& match self.kind {
				Kind::CheckIn => {
					self.delivered == 0
						&& !matches!(
							self.state,
							State::Sending { .. } | State::Between { .. } | State::Finished { release: Some(_), .. }
						)
				}
				Kind::Reminder => {
					self.admitted == 0 && !matches!(self.state, State::Admitting | State::Deferred { .. })
				}
			}
	}
	/// The occurrence keeps its original due time for cadence and expiry.
	fn wake_at(&self, limit: u32) -> u64 {
		match self.state {
			// A raised operator limit can make this occurrence eligible on restart.
			State::Deferred {
				reason: Delay::HourlyLimit { limit: previous },
				..
			} if limit > previous => self.due,
			State::Deferred { retry_at, .. } => {
				let until = self
					.repeat
					.map_or(OVERDUE + 1, |repeat| repeat.every_seconds.min(OVERDUE + 1));
				retry_at.min(self.due.saturating_add(until))
			}
			_ => self.due,
		}
	}
	fn unclaimed(&self) -> bool {
		matches!(self.state, State::Scheduled | State::Deferred { .. })
	}
	fn forget_at(&self) -> Option<u64> {
		match self.state {
			State::Finished { at, release: None, .. } => Some(at.saturating_add(RETENTION + 1)),
			_ => None,
		}
	}
	fn needs_worker(&self) -> bool {
		self.active() || matches!(self.state, State::Finished { release: Some(_), .. })
	}

	fn active(&self) -> bool {
		!matches!(self.state, State::Finished { .. })
	}
	fn phase(&self) -> Value {
		match self.state {
			State::Scheduled => json!("scheduled"),
			State::Deferred {
				reason: Delay::HourlyLimit { .. },
				..
			} => json!("waiting-for-hourly-limit"),
			State::Deferred {
				reason: Delay::WorkerBusy,
				..
			} => json!("waiting-for-worker"),
			State::Sending { .. } => json!("sending"),
			State::Between { .. } => json!("continuing"),
			State::Admitting => json!("admitting"),
			State::Finished { outcome, .. } => json!(outcome),
		}
	}
	fn report(&self) -> Value {
		let mut report = json!({
			"id": self.id, "kind": self.kind, "due": stamp::rfc3339(self.due), "text": self.text,
			"state": self.phase(), "repeat": self.repeat, "occurrence": self.occurrence,
			"delivered": self.delivered, "admitted": self.admitted, "skipped": self.skipped,
		});
		if let State::Deferred { retry_at, .. } = self.state {
			report["retry_at"] = json!(stamp::rfc3339(retry_at));
		}
		report
	}
}

#[derive(Default, Serialize, Deserialize)]
struct Book {
	rows: Vec<Reminder>,
}

impl Book {
	fn prune(&mut self, at: u64) -> bool {
		let before = self.rows.len();
		self.rows.retain(|r| r.forget_at().is_none_or(|due| at < due));
		self.rows.len() != before
	}
	fn read(root: &Path) -> Result<Self, Error> {
		let book: Self = store::read_unleased_bounded(&root.join(DIRECTORY), FILE, MAX_BYTES)?.unwrap_or_default();
		if book.rows.len() > MAX_ROWS || book.rows.iter().any(|row| !row.valid()) {
			return Err(Error::unreadable(FILE, "invalid reminder table"));
		}
		Ok(book)
	}

	/// Confirm the visible rename while holding the table lock before its
	/// state authorizes external work. Used on first read after a restart or
	/// a changed inode, including recovery from a prior unsettled write.
	fn confirmed(root: &Path) -> Result<Self, Error> {
		Self::edit(root, |book| Ok((std::mem::take(book), false)))
	}

	fn edit<T>(root: &Path, update: impl FnOnce(&mut Self) -> Result<(T, bool), Error>) -> Result<T, Error> {
		let lock = Directory::open_within(root.join(DIRECTORY), "lock", Duration::from_secs(1))?;
		let mut book = Self::read(root)?;
		let (value, changed) = update(&mut book)?;
		if changed {
			let bytes = store::encode(FILE, &book, MAX_BYTES)?;
			atomic::replace(&lock, FILE, [bytes.as_slice()])?;
		} else {
			// A prior writer may have received an unsettled result after rename.
			// Confirm its visible directory entry before acknowledging a replay.
			lock.sync().map_err(Error::io("confirming the reminder table"))?;
		}
		Ok(value)
	}

	fn set(root: &Path, original: &Reminder, next: State) -> Result<bool, Error> {
		let mut replacement = original.clone();
		replacement.state = next;
		Self::replace(root, original, replacement)
	}

	fn replace(root: &Path, original: &Reminder, replacement: Reminder) -> Result<bool, Error> {
		Self::edit(root, |book| {
			let Some(row) = book.rows.iter_mut().find(|r| *r == original) else {
				return Ok((false, false));
			};
			*row = replacement;
			Ok((true, true))
		})
	}
}

fn valid_id(id: &str) -> Result<(), Error> {
	if !(1..=48).contains(&id.len()) || !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-') {
		return Err(Error::Usage(
			"a reminder id takes 1–48 ASCII letters, digits, dashes or underscores".into(),
		));
	}
	Ok(())
}

fn valid_text(text: &str) -> bool {
	!text.trim().is_empty()
		&& text.len() <= 512
		&& !text
			.chars()
			.any(|c| c.is_control() || matches!(c, '\u{2028}' | '\u{2029}'))
}

pub struct Request<'a> {
	pub kind: Kind,
	pub id: &'a str,
	pub when: When,
	pub repeat: Option<Repeat>,
	pub text: &'a str,
}

pub fn create(
	root: &Path,
	scope: Scope,
	request: Request<'_>,
	at: u64,
	spend: impl FnOnce() -> Result<(), Error>,
) -> Result<Value, Error> {
	let Request {
		kind,
		id,
		when,
		repeat,
		text,
	} = request;
	valid_id(id)?;
	if !valid_text(text) {
		return Err(Error::Usage(
			"a reminder takes one nonempty line of up to 512 UTF-8 bytes".into(),
		));
	}
	Book::edit(root, |book| {
		book.prune(at);
		if let Some(row) = book.rows.iter().find(|r| r.scope == scope && r.id == id) {
			if row.kind != kind || row.text != text || row.when != when || row.repeat != repeat {
				return Err(Error::Usage(
					"this reminder id already names a different request here".into(),
				));
			}
			return Ok((row.report(), false));
		}
		let due = when.due(at)?;
		if let Some(repeat) = repeat
			&& due.saturating_add(repeat.span()).saturating_sub(at) > HORIZON
		{
			return Err(Error::Usage("all repeat times must fall within 30 days".into()));
		}
		if book.rows.len() >= MAX_ROWS
			|| book.rows.iter().filter(|r| r.active()).count() >= MAX_ACTIVE
			|| book.rows.iter().filter(|r| r.active() && r.scope == scope).count() >= MAX_HERE
		{
			return Err(Error::Usage("the reminder limit has been reached".into()));
		}
		let row = Reminder {
			id: id.into(),
			scope,
			kind,
			when,
			repeat,
			occurrence: 1,
			delivered: 0,
			admitted: 0,
			skipped: 0,
			due,
			text: text.into(),
			operation: operation()?,
			state: State::Scheduled,
		};
		let report = row.report();
		spend()?;
		book.rows.push(row);
		Ok((report, true))
	})
}

fn operation() -> Result<String, Error> {
	let mut entropy = [0; 16];
	rooms_platform::entropy::fill(&mut entropy).map_err(|e| Error::Entropy(e.to_string()))?;
	Ok(format!("reminder-{}", lower_hex(&entropy)))
}

pub fn list(root: &Path, scope: &Scope) -> Result<Value, Error> {
	let mut rows: Vec<_> = Book::read(root)?
		.rows
		.into_iter()
		.filter(|r| &r.scope == scope)
		.collect();
	rows.sort_by_key(|r| r.due);
	Ok(json!(rows.iter().map(Reminder::report).collect::<Vec<_>>()))
}

pub fn cancel(root: &Path, scope: &Scope, id: &str, spend: impl FnOnce() -> Result<(), Error>) -> Result<Value, Error> {
	valid_id(id)?;
	Book::edit(root, |book| {
		let row = book
			.rows
			.iter_mut()
			.find(|r| &r.scope == scope && r.id == id)
			.ok_or_else(|| Error::Usage("no such reminder in this conversation".into()))?;
		match row.state {
			State::Scheduled | State::Deferred { .. } => {
				row.state = State::Finished {
					outcome: Outcome::Cancelled,
					at: now(),
					release: None,
				}
			}
			State::Between { base } => {
				row.state = State::Finished {
					outcome: Outcome::Cancelled,
					at: now(),
					release: Some(base),
				}
			}
			State::Admitting | State::Sending { .. } => {
				return Err(Error::Usage("delivery has already started".into()));
			}
			State::Finished { .. } => return Ok((row.report(), false)),
		}
		spend()?;
		Ok((row.report(), true))
	})
}

/// Occurrences whose admission reply the timer can still request, so the
/// turn ledger can retain their idempotency records across process restarts.
pub struct PendingCheckIns {
	pub admitting: std::collections::BTreeSet<String>,
	pub live: std::collections::BTreeSet<String>,
}

pub fn pending_check_ins(root: &Path) -> Result<PendingCheckIns, Error> {
	let mut pending = PendingCheckIns {
		admitting: Default::default(),
		live: Default::default(),
	};
	for row in Book::read(root)?.rows {
		if row.kind == Kind::CheckIn && (row.unclaimed() || row.state == State::Admitting) {
			if row.state == State::Admitting {
				pending.admitting.insert(row.operation.clone());
			}
			pending.live.insert(row.operation);
		}
	}
	Ok(pending)
}

pub fn status(root: &Path) -> Result<Value, Error> {
	let book = Book::read(root)?;
	let mut counts = serde_json::Map::new();
	for row in book.rows {
		let state = row.phase().as_str().unwrap_or("unknown").to_owned();
		let count = counts.entry(state).or_insert(json!(0));
		*count = json!(count.as_u64().unwrap_or(0) + 1);
	}
	Ok(Value::Object(counts))
}

#[cfg(test)]
mod tests;
