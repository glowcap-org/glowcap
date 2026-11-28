//! Rolling admission per conversation. The last event's decision is written
//! before the turn ledger acts on it. Admission visits events in order and
//! makes each ledger change durable before the next decision replaces it.
mod scheduled;
pub use scheduled::ScheduledDecision;

use super::{
	classify::{Seq, Trigger},
	error::Error,
	rooms::{ConversationId, Cursor},
	stamp,
	store::{self, Store},
};
use serde::{Deserialize, Serialize};
use std::{
	collections::{BTreeMap, BTreeSet, VecDeque},
	fs,
	path::Path,
	time::Duration,
};

const WINDOW: Duration = Duration::from_secs(3600);
const DIRECTORY: &str = "availability";
const PREFIX: &str =
	"I skipped your request because I reached my hourly limit in this conversation. Please ask me again at or after ";
const SUFFIX: &str = ". Further requests before then are also skipped.";

pub fn message(until: u64) -> String {
	format!("{PREFIX}{}{SUFFIX}", stamp::rfc3339(until))
}

/// A bot receiving another bot's automatic notice in a DM must not answer it.
pub fn is_notice(text: &str) -> bool {
	text.strip_prefix(PREFIX)
		.and_then(|s| s.strip_suffix(SUFFIX))
		.is_some_and(|s| {
			s.len() == 20
				&& s.bytes().zip(b"0000-00-00T00:00:00Z").all(|(actual, expected)| {
					if *expected == b'0' {
						actual.is_ascii_digit()
					} else {
						actual == *expected
					}
				})
		})
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Decision {
	Start,
	Notify(u64),
	Skip,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Notice {
	Pending,
	Posted,
	Unconfirmed,
	Refused,
}

#[derive(Serialize, Deserialize)]
struct Record {
	conversation: ConversationId,
	// At most one bucket for each second in the rolling hour.
	starts: VecDeque<(u64, u32)>,
	last: Option<(Cursor, Seq, Decision)>,
	#[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
	scheduled: BTreeSet<String>,
	notice: Option<(Cursor, u64, Notice)>,
	skipped: u64,
	limit: u32,
}

impl Record {
	fn retry_at(&self, now: u64, limit: u32) -> Option<u64> {
		let mut seen = 0;
		for &(at, count) in self.starts.iter().rev() {
			let expires = at.saturating_add(WINDOW.as_secs());
			if expires <= now {
				break;
			}
			seen += count;
			if seen >= limit {
				return Some(expires);
			}
		}
		None
	}

	fn charge(&mut self, time: Duration) {
		let now = time.as_secs();
		while self
			.starts
			.front()
			.is_some_and(|(at, _)| at.saturating_add(WINDOW.as_secs()) <= now)
		{
			self.starts.pop_front();
		}
		// Round starts up to the published UTC precision, so a slot can
		// never reopen before its full hour, even across a clock correction.
		let at = now.saturating_add(u64::from(time.subsec_nanos() != 0));
		let at = self.starts.back().map_or(at, |(last, _)| at.max(*last));
		if let Some((previous, count)) = self.starts.back_mut()
			&& *previous == at
		{
			*count += 1;
		} else {
			self.starts.push_back((at, 1));
		}
	}

	fn decide(&mut self, event: &Trigger, time: Duration, limit: u32) -> Decision {
		if let Some((cursor, _, decision)) = &self.last
			&& cursor == &event.event
		{
			return *decision;
		}
		self.limit = limit;
		let now = time.as_secs();

		let decision = if let Some(until) = self.retry_at(now, limit) {
			if self
				.notice
				.as_ref()
				.is_none_or(|(_, asked_again_at, _)| now >= *asked_again_at)
			{
				self.skipped = 1;
				self.notice = Some((event.event.clone(), until, Notice::Pending));
				Decision::Notify(until)
			} else {
				self.skipped = self.skipped.saturating_add(1);
				Decision::Skip
			}
		} else {
			self.skipped = 0;
			self.notice = None;
			self.charge(time);
			Decision::Start
		};
		self.last = Some((event.event.clone(), event.seq, decision));
		decision
	}
}

fn records(root: &Path, mut visit: impl FnMut(&Path, Record) -> Result<(), Error>) -> Result<(), Error> {
	let dir = root.join(DIRECTORY);
	let entries = match fs::read_dir(&dir) {
		Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
		result => result.map_err(Error::io("listing conversation availability"))?,
	};
	for entry in entries {
		let path = entry.map_err(Error::io("reading conversation availability"))?.path();
		if path.extension().is_some_and(|ext| ext == "json")
			&& let Some(name) = path.file_name().and_then(|s| s.to_str())
			&& let Some(record) = store::read_unleased(&dir, name)?
		{
			visit(&path, record)?;
		}
	}
	Ok(())
}

#[derive(Serialize)]
pub struct Refusal {
	notice: Notice,
	skipped: u64,
	retry_at: String,
}

pub fn report(root: &Path, limit: Option<u32>) -> Result<BTreeMap<ConversationId, Refusal>, Error> {
	let now = stamp::seconds();
	let mut active = BTreeMap::new();
	records(root, |_, record| {
		if let Some((_, _, notice)) = record.notice
			&& let Some(until) = record.retry_at(now, limit.unwrap_or(record.limit))
		{
			active.insert(
				record.conversation,
				Refusal {
					notice,
					skipped: record.skipped,
					retry_at: stamp::rfc3339(until),
				},
			);
		}
		Ok(())
	})?;
	Ok(active)
}

/// The ledger row identifies the exact refusal. A delayed finish for an
/// earlier window must not change the current window's delivery status.
pub fn observed(store: &Store, conversation: &ConversationId, event: &Cursor, outcome: Notice) -> Result<(), Error> {
	let name = format!("{}.json", store::file_stem(conversation));
	if let Some(mut record) = store.read_in::<Record>(DIRECTORY, &name)?
		&& let Some((refused, _, state)) = &mut record.notice
		&& refused == event
		&& *state != outcome
		&& *state != Notice::Posted
	{
		*state = outcome;
		store.write_in(DIRECTORY, &name, &record)?;
	}
	Ok(())
}

pub struct Gate {
	limit: u32,
	next_prune: u64,
}

impl Gate {
	pub fn new(limit: u32) -> Self {
		Self { limit, next_prune: 0 }
	}

	pub fn decide(
		&mut self,
		store: &Store,
		conversation: &ConversationId,
		event: &Trigger,
		cursor: Seq,
	) -> Result<Decision, Error> {
		let time = stamp::since_epoch();
		self.prune(store, cursor, time.as_secs())?;
		let (name, mut record) = self.load(store, conversation)?;
		let decision = record.decide(event, time, self.limit);
		store.write_in(DIRECTORY, &name, &record)?;
		Ok(decision)
	}

	fn prune(&mut self, store: &Store, cursor: Seq, now: u64) -> Result<(), Error> {
		if now >= self.next_prune {
			let mut live = None;
			records(store.root(), |path, record| {
				if record
					.starts
					.back()
					.is_none_or(|(at, _)| at.saturating_add(WINDOW.as_secs()) <= now)
					&& record.last.is_none_or(|(_, seq, _)| seq < cursor)
				{
					if !record.scheduled.is_empty() {
						if live.is_none() {
							live = Some(super::reminders::pending_check_ins(store.root())?.live);
						}
						if live
							.as_ref()
							.is_some_and(|pending| !record.scheduled.is_disjoint(pending))
						{
							return Ok(());
						}
					}
					fs::remove_file(path).map_err(Error::io("retiring an expired admission record"))?;
				}
				Ok(())
			})?;
			self.next_prune = now.saturating_add(WINDOW.as_secs());
		}
		Ok(())
	}

	fn load(&self, store: &Store, conversation: &ConversationId) -> Result<(String, Record), Error> {
		let name = format!("{}.json", store::file_stem(conversation));
		let record: Record = store.read_in(DIRECTORY, &name)?.unwrap_or_else(|| Record {
			conversation: conversation.clone(),
			starts: VecDeque::new(),
			last: None,
			scheduled: BTreeSet::new(),
			notice: None,
			skipped: 0,
			limit: self.limit,
		});
		Ok((name, record))
	}
}

#[cfg(test)]
mod tests;
