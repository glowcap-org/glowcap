//! Dispatch only after durably claiming the exact observed base. If a crash
//! separates the claim and the call, conservatively report uncertainty.
use super::*;
use crate::bot::fault::{self, Kill};
use crate::bot::{
	link::Link,
	rooms::{
		RoomsErrorKind,
		captp::{Attached, Live},
	},
};
use rooms_services::session::attached::{self, EffectStatus, Holder, Release};

use tokio::sync::{mpsc, oneshot};

pub async fn run(
	root: &Path,
	rooms: &Attached,
	grant: &str,
	limit: u32,
	checkins: mpsc::Sender<CheckIn>,
) -> Result<(), Error> {
	// A damaged timer table or transient filesystem error must not tear down
	// an unrelated harness turn. Report the failure and resume from disk.
	loop {
		if let Err(error) = watch(root, rooms, grant, limit, &checkins).await {
			store::Log::in_directory(root).line(
				"the reminder timer could not read or update its state; check reminders/schedules.json and the bot directory",
			);
			let delay = if error.is_transient() { 2 } else { 60 };
			tokio::time::sleep(Duration::from_secs(delay)).await;
		}
	}
}

async fn watch(
	root: &Path,
	rooms: &Attached,
	grant: &str,
	limit: u32,
	checkins: &mpsc::Sender<CheckIn>,
) -> Result<(), Error> {
	// Turn verbs run in other processes. An atomic replacement changes the
	// inode. Idle ticks stat only the small table's name and touch no session.
	use std::os::unix::fs::MetadataExt;
	let mut last = None;
	let mut snapshot = Book::default();
	let mut next = 0;
	let mut tick = tokio::time::interval(Duration::from_secs(1));
	tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
	loop {
		tick.tick().await;
		let at = now();
		let mark = match std::fs::symlink_metadata(root.join(DIRECTORY).join(FILE)) {
			Ok(m) => (m.ino(), m.ctime(), m.ctime_nsec()),
			Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
			Err(e) => return Err(Error::io("checking the reminder timer")(e)),
		};
		if last == Some(mark) && at < next {
			continue;
		}
		if last != Some(mark) {
			snapshot = Book::confirmed(root)?;
			last = Some(mark);
		}
		let rows = &snapshot.rows;
		next = rows.iter().filter_map(Reminder::forget_at).min().unwrap_or(u64::MAX);
		if next <= at {
			Book::edit(root, |book| Ok(((), book.prune(at))))?;
			continue;
		}
		if !rows.iter().any(Reminder::needs_worker) {
			continue;
		}
		if !Link::load(root)?.is_some_and(|link| link.fingerprint() == grant) {
			next = 0;
			continue;
		}
		for row in rows {
			if !row.needs_worker() {
				continue;
			}
			if row.scope.grant != grant {
				lost(root, row)?;
				continue;
			}
			let wake_at = row.wake_at(limit);
			next = next.min(wake_at);
			if wake_at > at {
				continue;
			}
			if row.unclaimed()
				&& let Some(repeat) = row.repeat
			{
				// An entire elapsed slot is missed. Move directly to the current
				// slot or retire the series, without dispatching a backlog.
				let age = at.saturating_sub(row.due);
				if age >= repeat.every_seconds {
					let skipped = age.div_ceil(repeat.every_seconds);
					skip(root, row, skipped)?;
					continue;
				}
			}
			// A lost connection can outlive the grace period. Stop promising work
			// even while the holder is unreachable. Its release remains owed.
			if at.saturating_sub(row.due) > OVERDUE {
				match row.state {
					State::Sending { base } => {
						finish(root, row, Outcome::Unconfirmed, Some(base))?;
						continue;
					}
					State::Between { base } => {
						finish(root, row, Outcome::Expired, Some(base))?;
						continue;
					}
					_ => {}
				}
			}
			if row.state == State::Admitting
				&& (at.saturating_sub(row.due) > OVERDUE
					|| row
						.repeat
						.is_some_and(|repeat| at.saturating_sub(row.due) >= repeat.every_seconds))
			{
				finish(root, row, Outcome::Unconfirmed, None)?;
				continue;
			}
			if row.unclaimed() && at.saturating_sub(row.due) > OVERDUE {
				if row.repeat.is_some() {
					skip(root, row, 1)?;
				} else {
					finish(root, row, Outcome::Expired, None)?;
				}
				continue;
			}
			let live = match rooms.live().await {
				Ok(live) => live,
				Err(error) if matches!(error.kind, RoomsErrorKind::Revoked | RoomsErrorKind::Denied) => {
					lost(root, row)?;
					continue;
				}
				Err(_) => break,
			};
			match deliver(root, row, &live, checkins).await {
				Ok(()) => {}
				Err(Failure::Local(error)) => return Err(error),
				Err(Failure::Session(error)) => {
					rooms.lost(&live, &error).await;
					if matches!(error, attached::Error::Revoked | attached::Error::Refused) {
						lost(root, row)?;
					}
				}
			}
		}
	}
}

/// A retiring grant can observe and release its own in-flight posts. This
/// pass never claims a scheduled occurrence or admits a task. Replacement
/// shares its existing deadline with these reads.
pub async fn settle_receipts(root: &Path, rooms: &Attached, grant: &str) -> Result<(), Error> {
	if !root
		.join(DIRECTORY)
		.join(FILE)
		.try_exists()
		.map_err(Error::io("checking reminders on grant replacement"))?
	{
		return Ok(());
	}
	for mut row in Book::confirmed(root)?.rows {
		if row.scope.grant != grant {
			continue;
		}
		let settling = |state: &State| {
			matches!(
				state,
				State::Sending { .. } | State::Between { .. } | State::Finished { release: Some(_), .. }
			)
		};
		if !settling(&row.state) {
			continue;
		}
		let Ok(live) = rooms.live().await else { break };
		// Observing a committed send makes a release due. A second pass can
		// give that receipt back under the original grant.
		for _ in 0..2 {
			match settle(root, &row, &live).await {
				Ok(()) => {}
				Err(Failure::Session(_)) => break,
				Err(Failure::Local(error)) => return Err(error),
			}
			let Some(updated) = Book::read(root)?
				.rows
				.into_iter()
				.find(|r| r.operation == row.operation)
			else {
				break;
			};
			if row == updated || !settling(&updated.state) {
				break;
			}
			row = updated;
		}
	}
	Ok(())
}

pub fn access_lost(root: &Path, grant: &str) -> Result<(), Error> {
	for row in Book::read(root)?.rows {
		if row.scope.grant == grant && row.needs_worker() {
			lost(root, &row)?;
		}
	}
	Ok(())
}

fn lost(root: &Path, row: &Reminder) -> Result<(), Error> {
	let outcome = match row.state {
		State::Scheduled | State::Deferred { .. } => Outcome::AccessLost,
		State::Sending { .. } | State::Admitting => Outcome::Unconfirmed,
		State::Between { .. } => Outcome::AccessLost,
		State::Finished { outcome, .. } => outcome,
	};
	finish(root, row, outcome, None)
}

fn finish(root: &Path, row: &Reminder, outcome: Outcome, release: Option<u64>) -> Result<(), Error> {
	Book::set(
		root,
		row,
		State::Finished {
			outcome,
			at: now(),
			release,
		},
	)?;
	Ok(())
}

fn skip(root: &Path, row: &Reminder, slots: u64) -> Result<(), Error> {
	let Some(repeat) = row.repeat else {
		return Err(Error::unreadable(FILE, "missing reminder cadence"));
	};
	let left = repeat.count - row.occurrence + 1;
	let mut next = row.clone();
	next.skipped += left.min(u32::try_from(slots).unwrap_or(u32::MAX));
	if slots >= u64::from(left) {
		next.occurrence = repeat.count;
		next.due += u64::from(left - 1) * repeat.every_seconds;
		next.state = State::Finished {
			outcome: Outcome::Expired,
			at: now(),
			release: None,
		};
		Book::replace(root, row, next)?;
		return Ok(());
	}
	advance_from(root, row, next, slots)
}

fn advance(root: &Path, row: &Reminder, slots: u64) -> Result<(), Error> {
	advance_from(root, row, row.clone(), slots)
}

fn advance_from(root: &Path, row: &Reminder, mut next: Reminder, slots: u64) -> Result<(), Error> {
	let Some(repeat) = row.repeat else {
		return Err(Error::unreadable(FILE, "missing reminder cadence"));
	};
	if slots > u64::from(repeat.count - row.occurrence) {
		return finish(root, row, Outcome::Expired, None);
	}
	next.occurrence += slots as u32;
	next.due += slots * repeat.every_seconds;
	// A fresh random id for every occurrence, persisted with its due time.
	next.operation = operation()?;
	next.state = State::Scheduled;
	Book::replace(root, row, next)?;
	Ok(())
}

enum Failure {
	Local(Error),
	Session(attached::Error),
}
impl From<Error> for Failure {
	fn from(error: Error) -> Self {
		Self::Local(error)
	}
}
impl From<attached::Error> for Failure {
	fn from(error: attached::Error) -> Self {
		Self::Session(error)
	}
}

async fn deliver(root: &Path, row: &Reminder, live: &Live, checkins: &mpsc::Sender<CheckIn>) -> Result<(), Failure> {
	if !row.unclaimed() && row.state != State::Admitting {
		return settle(root, row, live).await;
	}
	let snapshot = live.view.posting_snapshot().await?;
	if !row.scope.matches(&live.grant, &snapshot) {
		let outcome = if row.state == State::Admitting {
			Outcome::Unconfirmed
		} else {
			Outcome::TargetChanged
		};
		return Ok(finish(root, row, outcome, None)?);
	}
	if row.kind == Kind::CheckIn {
		return Ok(check(root, row, checkins).await?);
	}
	let mut claim = row.clone();
	let base = snapshot.revision;
	claim.state = State::Sending { base };
	if !Book::set(root, row, claim.state.clone())? {
		return Ok(());
	}
	let line = format!("{PREFIX}{}", row.text);
	fault::hit(Kill::BeforeSend);
	let status = live
		.view
		.say_at(&row.operation, base, row.scope.conversation(), &line)
		.await;
	fault::hit(Kill::AfterSend);
	Ok(record(root, &claim, base, status?)?)
}

/// Observe or release an existing receipt. This path cannot submit a post
/// or a check-in, including when replacing a grant.
async fn settle(root: &Path, row: &Reminder, live: &Live) -> Result<(), Failure> {
	let line = format!("{PREFIX}{}", row.text);
	let conversation = row.scope.conversation();
	let base = match row.state {
		State::Sending { base } => {
			if live.view.holder(&row.operation).await? != Holder::Mine {
				return Ok(finish(root, row, Outcome::Unconfirmed, None)?);
			}
			let status = live
				.view
				.observe(&row.operation, base, "say", &[conversation.into(), line])
				.await?;
			return Ok(record(root, row, base, status)?);
		}
		State::Between { base }
		| State::Finished {
			release: Some(base), ..
		} => base,
		_ => return Ok(()),
	};
	match live
		.view
		.release_line(&row.operation, base, conversation, &line)
		.await?
	{
		Release::Running => {}
		Release::Released | Release::Kept => match row.state {
			State::Between { .. } => advance(root, row, 1)?,
			State::Finished { outcome, at, .. } => {
				Book::set(
					root,
					row,
					State::Finished {
						outcome,
						at,
						release: None,
					},
				)?;
			}
			_ => {}
		},
	}
	Ok(())
}

fn record(root: &Path, claim: &Reminder, base: u64, status: EffectStatus) -> Result<(), Error> {
	match status {
		EffectStatus::Committed => {
			let mut next = claim.clone();
			next.delivered += 1;
			next.state = if next.repeat.is_some_and(|r| next.occurrence < r.count) {
				State::Between { base }
			} else {
				State::Finished {
					outcome: Outcome::Delivered,
					at: now(),
					release: Some(base),
				}
			};
			Book::replace(root, claim, next)?;
		}
		EffectStatus::Unsent => finish(root, claim, Outcome::Refused, Some(base))?,
		EffectStatus::Conflict => {
			Book::set(root, claim, State::Scheduled)?;
		}
		EffectStatus::Unknown => finish(root, claim, Outcome::Unconfirmed, Some(base))?,
		EffectStatus::Pending if now().saturating_sub(claim.due) > OVERDUE => {
			finish(root, claim, Outcome::Unconfirmed, Some(base))?
		}
		EffectStatus::Pending => {}
	}
	Ok(())
}

async fn check(root: &Path, row: &Reminder, inbox: &mpsc::Sender<CheckIn>) -> Result<(), Error> {
	let permit = match inbox.try_reserve() {
		Ok(permit) => permit,
		Err(_) => return Ok(()),
	};
	let mut claim = row.clone();
	if claim.state != State::Admitting {
		claim.state = State::Admitting;
		if !Book::set(root, row, State::Admitting)? {
			return Ok(());
		}
	}
	let (reply, answer) = oneshot::channel();
	let request = CheckIn {
		scope: row.scope.clone(),
		operation: row.operation.clone(),
		task: row.text.clone(),
		reply,
	};
	permit.send(request);
	// The engine can be stopping. Keep the same operation if acknowledgement
	// is lost, so its durable admission index decides whether work exists.
	match tokio::time::timeout(Duration::from_secs(3), answer).await {
		Ok(Ok(Admission::Admitted)) => {
			let mut next = claim.clone();
			next.admitted += 1;
			if next.repeat.is_some_and(|r| next.occurrence < r.count) {
				advance_from(root, &claim, next, 1)?;
			} else {
				next.state = State::Finished {
					outcome: Outcome::Admitted,
					at: now(),
					release: None,
				};
				Book::replace(root, &claim, next)?;
			}
		}
		Ok(Ok(Admission::Busy)) => {
			Book::set(
				root,
				&claim,
				State::Deferred {
					retry_at: now().saturating_add(10),
					reason: Delay::WorkerBusy,
				},
			)?;
		}
		Ok(Ok(Admission::HourlyLimit { until, limit })) => {
			Book::set(
				root,
				&claim,
				State::Deferred {
					retry_at: until,
					reason: Delay::HourlyLimit { limit },
				},
			)?;
		}
		Ok(Ok(Admission::Refused)) => finish(root, &claim, Outcome::Refused, None)?,
		_ => {}
	}
	Ok(())
}

#[cfg(test)]
mod tests {
	use super::*;
	use rooms_testing::scratch::Scratch;

	fn start(root: &Path, kind: Kind) -> Reminder {
		let scope = Scope {
			kind: crate::bot::rooms::Kind::Direct,
			conversation: "here".into(),
			grant: "a".repeat(64),
			target: "b".repeat(64),
		};
		create(
			root,
			scope,
			Request {
				id: "review",
				kind,
				when: When::After(1),
				repeat: Some(Repeat {
					every_seconds: 60,
					count: 4,
				}),
				text: "Review the open questions",
			},
			now(),
			|| Ok(()),
		)
		.unwrap();
		Book::read(root).unwrap().rows.pop().unwrap()
	}

	#[test]
	fn advancing_skips_elapsed_slots_and_a_stale_claim_cannot_rearm() {
		let root = Scratch::create("reminder-slot");
		let first = start(&root, Kind::Reminder);
		skip(&root, &first, 2).unwrap();
		let third = Book::read(&root).unwrap().rows.pop().unwrap();
		assert_eq!(third.occurrence, 3);
		assert_eq!(third.due, first.due + 120);
		assert_ne!(third.operation, first.operation);
		assert_eq!(third.delivered, 0);
		assert_eq!(third.skipped, 2);
		assert!(!Book::set(&root, &first, State::Scheduled).unwrap());
		skip(&root, &third, 2).unwrap();
		assert_eq!(list(&root, &third.scope).unwrap()[0]["state"], "expired");
	}

	#[tokio::test]
	async fn a_lost_admission_reply_reuses_its_occurrence_without_claiming_task_success() {
		let root = Scratch::create("reminder-admission");
		let first = start(&root, Kind::CheckIn);
		let (tx, mut rx) = mpsc::channel::<CheckIn>(1);
		let (result, ()) = tokio::join!(check(&root, &first, &tx), async {
			let request = rx.recv().await.unwrap();
			assert_eq!(request.operation, first.operation);
			drop(request.reply);
		});
		result.unwrap();
		assert!(
			super::super::pending_check_ins(&root)
				.unwrap()
				.admitting
				.contains(&first.operation)
		);
		let recovering = Book::read(&root).unwrap().rows.pop().unwrap();
		let (result, ()) = tokio::join!(check(&root, &recovering, &tx), async {
			let request = rx.recv().await.unwrap();
			assert_eq!(request.operation, first.operation);
			assert!(request.reply.send(Admission::Admitted).is_ok());
		});
		result.unwrap();
		let next = Book::read(&root).unwrap().rows.pop().unwrap();
		assert_eq!(next.occurrence, 2);
		assert_eq!(next.admitted, 1);
		assert_eq!(next.delivered, 0);
		assert_ne!(next.operation, first.operation);
		assert!(super::super::pending_check_ins(&root).unwrap().admitting.is_empty());
	}
}
