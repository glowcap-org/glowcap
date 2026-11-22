//! The delivering stage of a turn: send the reply's lines in order, each
//! under the operation the ledger fixed for it, until every line is settled.
//!
//! A line's base is its commit point. The ledger records it before the send,
//! and every later look at the operation uses it, so one operation is never
//! sent at two bases. After a restart or an unsettled send the operation is
//! observed, never sent blind. A commit is recorded before the line is kept,
//! so keeping is tried again after a crash and the session can release the
//! receipt.
//!
//! The session's receipt decides first, because it outlives a session
//! restart. A send still running is looked at until it settles. A receipt the
//! session does not hold proves nothing, because the session lets a settled
//! receipt go, so the line's echo in activity decides. Found, the line
//! posted. Not found in a complete read since the send's cursor, in the same
//! session run, the same operation goes out again at its base, which can post
//! at most once. When that resend is refused as a conflict, the operation can
//! never commit, and only a second such read sends the line under a new
//! operation at a fresh base. A receipt whose send no work will settle is
//! decided by the echo alone. Whenever activity cannot tell, the line is given
//! up on without sending it again, and `status` counts it as unconfirmed.
//!
//! Every receipt delivery stops caring about is kept or released, so none is
//! left to fill the session. A line settled without being kept is recorded
//! first, so a restart before its release finishes the release and never
//! sends the line. Delivery does not give up on a session that is
//! unreachable or paused, because giving up would leave a trigger with no
//! reply while the session may still hold part of it. The wait and the
//! failure reach `status`.
use super::{Env, Step, backoff::Backoff, failure_part, operation};
use crate::bot::{
	error::Error,
	fault::{self, Point},
	inbox,
	ledger::{Attempt, Content, Ledger, Phase, TurnId},
	rooms::{
		Base, ConversationId, Cursor, Echo, Outcome, Outgoing, READ_DEADLINE, Rooms, RoomsError, RoomsErrorKind,
		SEND_DEADLINE,
	},
	status::{Access, Activity},
};
use std::{future::Future, time::Duration};
use tokio::{sync::watch, time::timeout};

/// How many times in a row a line may go out under a new operation after the
/// session committed nothing before the tries slow down. A conflict refuses
/// the base, not the line, and a failure line would meet the same writes, so
/// the line is never replaced.
const MAX_REISSUES: u32 = 3;
/// How many looks may find a send still running before the looks slow down
/// and `status` reports the wait.
const MAX_LOOKS: u32 = 20;
/// How many times a release may be refused before the receipt is left with
/// the session. A send's worker that has not yet seen its reply refuses the
/// release until it does.
const MAX_RELEASE_REFUSALS: u32 = 3;

/// What delivery does next.
enum Next {
	Now,
	After(Duration),
	Finished,
}

/// The waits and counts one delivery keeps between steps.
struct Tries {
	standard: Backoff,
	slow: Backoff,
	reissues: u32,
	/// Releases of this line the session refused.
	refusals: u32,
	/// The next step sends the same operation at its base again instead of
	/// observing it, as this call. A paced send is repeated as the call it
	/// was, so a paced first send keeps a first send's meaning. A send whose
	/// receipt the session does not hold, with no echo in a complete read of
	/// activity, goes out as `Asked::Resend`.
	again: Option<Asked>,
}

impl Tries {
	fn settled(&mut self) {
		self.standard.reset();
		self.slow.reset();
		self.reissues = 0;
		self.refusals = 0;
	}
}

pub async fn run<R: Rooms>(env: &Env<'_, R>, id: TurnId, stop: &mut watch::Receiver<bool>) -> Result<Step, Error> {
	drive(env, id, stop, false).await
}

/// Settle the line of turn `id` that is already sent, and stop before
/// sending another. A line the session refused as a conflict stops there too,
/// to go out under a new operation later.
pub async fn settle_sent<R: Rooms>(
	env: &Env<'_, R>,
	id: TurnId,
	stop: &mut watch::Receiver<bool>,
) -> Result<Step, Error> {
	drive(env, id, stop, true).await
}

/// Whether turn `id` has a line sent, or about to be, that is not settled.
pub fn sent_unsettled<R: Rooms>(env: &Env<'_, R>, id: TurnId) -> bool {
	matches!(
		env.ledger.borrow().phase(id),
		Some(Phase::Sending {
			attempt: Attempt::Sent { .. }
				| Attempt::Committed { .. }
				| Attempt::Releasing { .. }
				| Attempt::Handed { .. },
			..
		})
	)
}

/// What `hand` did with the unsettled line of one turn.
pub enum Handed {
	/// The turn had no line sent and unsettled.
	Nothing,
	/// The send had not settled, so the new link decides the line by its
	/// echo alone. The old access holds its receipt.
	ToEcho { operation: String },
	/// The line posted and the old access kept it.
	Kept { operation: String },
	/// The old access released the receipt of a line it did not keep, and
	/// `unkept` says why keeping failed when it was tried.
	Released {
		operation: String,
		unkept: Option<RoomsError>,
	},
	/// The receipt stays with the session, which releases it once the old
	/// access is revoked.
	Held { operation: String, why: String },
}

/// Leave the unsettled line of turn `id` to the link that replaces this one.
/// Only this link's access can keep or release the line's receipt, so a line
/// still being sent is left to be settled by its echo alone. A line that
/// posted, or whose release is owed, is settled now. Unless `skip` names why
/// the session must not be called, an active access gets one more try at
/// keeping the line, or else releasing its receipt. Both calls are
/// idempotent, so a caller may cut this short and call again with `skip`.
pub async fn hand<R: Rooms>(env: &Env<'_, R>, id: TurnId, skip: Option<&str>) -> Result<Handed, Error> {
	let (conversation, part, attempt) = match env.ledger.borrow().phase(id) {
		Some(Phase::Sending {
			conversation,
			parts,
			sent,
			attempt,
			..
		}) => (conversation.clone(), parts.get(*sent).cloned(), attempt.clone()),
		_ => return Ok(Handed::Nothing),
	};
	let Some(part) = part else {
		return Ok(Handed::Nothing);
	};
	let operation = part.operation.clone();
	let base = match attempt {
		Attempt::Sent { base, after, .. } => {
			env.ledger
				.borrow_mut()
				.attempt(env.store, id, Attempt::Handed { base, after })?;
			return Ok(Handed::ToEcho { operation });
		}
		Attempt::Committed { base } | Attempt::Releasing { base } => base,
		Attempt::Unsent | Attempt::Handed { .. } => return Ok(Handed::Nothing),
	};
	let inactive = env.facts.borrow().access != Access::Active;
	let handed = match skip.or(inactive.then_some("the old access is not active")) {
		Some(why) => Handed::Held {
			operation,
			why: why.into(),
		},
		None => {
			let line = Outgoing {
				conversation: &conversation,
				text: &part.text,
				operation: &part.operation,
			};
			let kept = match attempt {
				Attempt::Committed { .. } => Some(within(SEND_DEADLINE, env.rooms.keep(&line, base)).await),
				_ => None,
			};
			match kept {
				Some(Ok(())) => Handed::Kept { operation },
				kept => {
					let unkept = kept.and_then(Result::err);
					match within(SEND_DEADLINE, env.rooms.release(&line, base)).await {
						Ok(()) => Handed::Released { operation, unkept },
						Err(error) => Handed::Held {
							operation,
							why: match unkept {
								Some(unkept) => {
									format!("keeping the line failed ({unkept}) and so did releasing it ({error})")
								}
								None => format!("releasing it failed ({error})"),
							},
						},
					}
				}
			}
		}
	};
	env.ledger.borrow_mut().part_sent(env.store, id)?;
	Ok(handed)
}

async fn drive<R: Rooms>(
	env: &Env<'_, R>,
	id: TurnId,
	stop: &mut watch::Receiver<bool>,
	sent_only: bool,
) -> Result<Step, Error> {
	let mut tries = Tries {
		standard: Backoff::standard(),
		slow: Backoff::slow(),
		reissues: 0,
		refusals: 0,
		again: None,
	};
	loop {
		if *stop.borrow() {
			return Ok(Step::Stopped);
		}
		if sent_only && !sent_unsettled(env, id) {
			return Ok(Step::Finished);
		}
		match step(env, id, &mut tries).await? {
			Next::Finished => return Ok(Step::Finished),
			Next::Now => {}
			Next::After(wait) => {
				if !super::waited(wait, stop).await {
					return Ok(Step::Stopped);
				}
			}
		}
	}
}

/// One call to the session for the next line, and the ledger change it earns.
async fn step<R: Rooms>(env: &Env<'_, R>, id: TurnId, tries: &mut Tries) -> Result<Next, Error> {
	env.ledger.borrow_mut().durable(env.store)?;
	let phase = env.ledger.borrow().phase(id).cloned();
	let (conversation, content, parts, sent, attempt) = match phase {
		Some(Phase::Sending {
			conversation,
			content,
			parts,
			sent,
			attempt,
			..
		}) => (conversation, content, parts, sent, attempt),
		Some(Phase::Done { .. }) => return Ok(Next::Finished),
		Some(Phase::Running { .. }) | None => {
			return Err(Ledger::invariant("a turn reached delivery without a reply"));
		}
	};
	let Some(part) = parts.get(sent) else {
		finish(env, id, &conversation)?;
		return Ok(Next::Finished);
	};
	let line = Outgoing {
		conversation: &conversation,
		text: &part.text,
		operation: &part.operation,
	};
	let began = env.access_changes.get();
	let turn = Turn {
		env,
		id,
		content,
		line,
		began,
	};
	match attempt {
		Attempt::Unsent => {
			let base = match within(SEND_DEADLINE, env.rooms.base()).await {
				Ok(base) => base,
				Err(error) => return turn.failed(&error, tries),
			};
			let after = env.ledger.borrow().cursor().clone();
			env.ledger.borrow_mut().attempt(
				env.store,
				id,
				Attempt::Sent {
					base,
					after: after.clone(),
					looks: 0,
				},
			)?;
			fault::hit(Point::BeforeSend);
			let answer = match within(SEND_DEADLINE, env.rooms.send(&line, base)).await {
				Ok(_) if fault::fails(Point::LateSend) => Err(late()),
				answer => answer,
			};
			fault::hit(Point::AfterSend);
			turn.answered(answer, Asked::FirstSend, base, after, 0, tries).await
		}
		Attempt::Sent { base, after, looks } => {
			let (answer, asked) = if let Some(asked) = tries.again.take() {
				let answer = within(SEND_DEADLINE, env.rooms.send(&line, base)).await;
				fault::hit(Point::AfterSend);
				(answer, asked)
			} else {
				(
					within(SEND_DEADLINE, env.rooms.observe(&line, base)).await,
					Asked::Observe,
				)
			};
			turn.answered(answer, asked, base, after, looks, tries).await
		}
		Attempt::Committed { base } => turn.keep(base, tries).await,
		Attempt::Releasing { base } => turn.release(base, tries).await,
		Attempt::Handed { after, .. } => turn.handed(&after, tries).await,
	}
}

/// Which call of an operation an answer is for.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Asked {
	/// The operation's first send, so a conflict means it committed nothing.
	FirstSend,
	/// The same operation sent again at its base after the session held no
	/// receipt for it and activity showed no echo. A conflict means the
	/// operation can never commit, but not that the line never posted under it.
	Resend,
	/// A look at an operation already sent. A conflict is its receipt saying
	/// it committed nothing.
	Observe,
}

/// The next line of one turn, as one step handles it.
struct Turn<'e, 'l, R: Rooms> {
	env: &'e Env<'e, R>,
	id: TurnId,
	content: Content,
	line: Outgoing<'l>,
	/// The access changes counted when this step began.
	began: u64,
}

impl<R: Rooms> Turn<'_, '_, R> {
	fn log(&self, what: &str) {
		self.env.store.log(&format!("turn {}: {what}", self.id.0));
	}

	/// Act on what a send or a look at it answered.
	async fn answered(
		&self,
		answer: Result<Outcome, RoomsError>,
		asked: Asked,
		base: Base,
		after: Cursor,
		looks: u32,
		tries: &mut Tries,
	) -> Result<Next, Error> {
		match answer {
			Ok(Outcome::Committed) => self.committed(base, tries),
			Ok(Outcome::Pending) => {
				// A running send cannot be released, so it is watched until it
				// settles, less often once it has run long.
				let looks = looks.saturating_add(1);
				if looks == MAX_LOOKS {
					let still = format!(
						"operation {} is still running in the session, which holds this conversation's next reply",
						self.line.operation
					);
					self.log(&format!("{still}. Looking less often"));
					self.env.facts.borrow_mut().failed(Activity::Sending, &still);
					self.env.publish();
				}
				let wait = if looks < MAX_LOOKS {
					tries.standard.next()
				} else {
					tries.slow.next()
				};
				let still = Attempt::Sent { base, after, looks };
				self.env.ledger.borrow_mut().attempt(self.env.store, self.id, still)?;
				Ok(Next::After(wait))
			}
			// No work will settle the receipt, so only activity can tell.
			Ok(Outcome::Unknown) => match self.echo(&after).await {
				Ok(Echo::Found) => self.committed(base, tries),
				Ok(Echo::NotFound | Echo::Restarted | Echo::Unknowable) => self.give_up(base),
				Err(error) => self.failed(&error, tries),
			},
			// The session may have let the receipt of a posted line go, so only
			// a complete read that finds no echo sends the operation again.
			Ok(Outcome::Absent) => match self.echo(&after).await {
				Ok(Echo::Found) => self.committed(base, tries),
				Ok(Echo::NotFound) => {
					self.log(&format!(
						"the session holds no receipt for operation {} and activity shows no echo. Sending it again \
						 at its base",
						self.line.operation
					));
					tries.again = Some(Asked::Resend);
					Ok(Next::Now)
				}
				Ok(Echo::Restarted | Echo::Unknowable) => self.give_up(base),
				Err(error) => self.failed(&error, tries),
			},
			Ok(Outcome::Conflict) => match asked {
				Asked::FirstSend | Asked::Observe => self.conflict(tries),
				Asked::Resend => match self.echo(&after).await {
					Ok(Echo::Found) => self.committed(base, tries),
					Ok(Echo::NotFound) => self.conflict(tries),
					Ok(Echo::Restarted | Echo::Unknowable) => self.give_up(base),
					Err(error) => self.failed(&error, tries),
				},
			},
			// Only a refusal that proves nothing was dispatched advises a wait,
			// so a paced send goes out again at its base as the same call and
			// is never looked at into a give-up.
			Err(error) if asked != Asked::Observe && error.retry_after.is_some() => {
				tries.again = Some(asked);
				self.failed(&error, tries)
			}
			Err(error) => self.failed(&error, tries),
		}
	}

	/// Record the commit, so a crash before the line is kept keeps it later.
	fn committed(&self, base: Base, tries: &mut Tries) -> Result<Next, Error> {
		let committed = Attempt::Committed { base };
		self.env
			.ledger
			.borrow_mut()
			.attempt(self.env.store, self.id, committed)?;
		fault::hit(Point::AfterCommit);
		self.env.access_active_since(self.began, Activity::Sending);
		self.env.publish();
		tries.settled();
		Ok(Next::Now)
	}

	/// Keep a committed line, then move to the next. A line the session will
	/// not keep still posted, so it is settled all the same, never said again,
	/// and its receipt is released.
	async fn keep(&self, base: Base, tries: &mut Tries) -> Result<Next, Error> {
		match within(SEND_DEADLINE, self.env.rooms.keep(&self.line, base)).await {
			Ok(()) => self.settled(tries),
			Err(error) if error.kind == RoomsErrorKind::Refused => {
				self.log(&format!(
					"a line to {} posted, but the session would not keep it: {error}. Releasing its receipt",
					self.line.conversation
				));
				self.releasing(base)?;
				Ok(Next::Now)
			}
			Err(error) => self.failed(&error, tries),
		}
	}

	/// Record the line settled, then move to the next.
	fn settled(&self, tries: &mut Tries) -> Result<Next, Error> {
		self.env.ledger.borrow_mut().part_sent(self.env.store, self.id)?;
		fault::hit(Point::AfterRecord);
		tries.settled();
		self.env.publish();
		Ok(Next::Now)
	}

	/// Record that the line is settled without being kept and its receipt is
	/// owed back, before anything asks the session to release it.
	fn releasing(&self, base: Base) -> Result<(), Error> {
		self.env
			.ledger
			.borrow_mut()
			.attempt(self.env.store, self.id, Attempt::Releasing { base })
	}

	/// Activity's answer to whether the line posted after `after`. A read the
	/// session refuses tells nothing, and repeating it will not help.
	async fn echo(&self, after: &Cursor) -> Result<Echo, RoomsError> {
		match within(READ_DEADLINE, self.env.rooms.echoed(&self.line, after)).await {
			Err(error) if error.kind == RoomsErrorKind::Refused => {
				self.log(&format!(
					"reading activity for operation {}: {error}",
					self.line.operation
				));
				Ok(Echo::Unknowable)
			}
			answer => answer,
		}
	}

	/// Release the receipt of a line settled without being kept, then move to
	/// the next. A session that does not answer, or asks for a wait, is asked
	/// again later. One that keeps refusing leaves the receipt with it, which
	/// the log says.
	async fn release(&self, base: Base, tries: &mut Tries) -> Result<Next, Error> {
		match within(SEND_DEADLINE, self.env.rooms.release(&self.line, base)).await {
			Ok(()) => fault::hit(Point::AfterRelease),
			Err(error) if error.kind == RoomsErrorKind::Refused => {
				tries.refusals = tries.refusals.saturating_add(1);
				if tries.refusals < MAX_RELEASE_REFUSALS {
					return Ok(Next::After(tries.standard.next()));
				}
				self.log(&format!(
					"the session kept the receipt of operation {}: {error}",
					self.line.operation
				));
			}
			Err(error) => return self.failed(&error, tries),
		}
		self.settled(tries)
	}

	/// Settle a line nobody can confirm, without sending it again, because a
	/// second send could post it twice. Its receipt is released next.
	fn give_up(&self, base: Base) -> Result<Next, Error> {
		self.releasing(base)?;
		self.unconfirmed(&format!(
			"the session cannot say whether operation {} to {} posted. Moving on without sending it again",
			self.line.operation, self.line.conversation
		));
		Ok(Next::Now)
	}

	/// Count a line given up on, and show why in the log and `status`.
	fn unconfirmed(&self, why: &str) {
		let mut facts = self.env.facts.borrow_mut();
		facts.unconfirmed += 1;
		facts.failed(Activity::Sending, why);
		drop(facts);
		self.log(why);
		self.env.publish();
	}

	/// Settle a line a replaced link's access sent, by its echo alone. That
	/// access holds the receipt, so this link neither keeps, releases, nor
	/// sends the line again.
	async fn handed(&self, after: &Cursor, tries: &mut Tries) -> Result<Next, Error> {
		let found = match self.echo(after).await {
			Ok(echo) => echo == Echo::Found,
			Err(error) => return self.failed(&error, tries),
		};
		let next = self.settled(tries)?;
		if found {
			self.log(&format!(
				"operation {} posted under the replaced link, whose access holds its receipt",
				self.line.operation
			));
		} else {
			self.unconfirmed(&format!(
				"the session cannot say whether operation {}, sent under the replaced link, posted. Moving on \
				 without sending it again",
				self.line.operation
			));
		}
		Ok(next)
	}

	fn conflict(&self, tries: &mut Tries) -> Result<Next, Error> {
		tries.reissues = tries.reissues.saturating_add(1);
		self.log(&format!(
			"the session committed nothing for operation {}. Sending it under a new one",
			self.line.operation
		));
		self.env
			.ledger
			.borrow_mut()
			.reissue(self.env.store, self.id, operation()?)?;
		Ok(Next::After(if tries.reissues <= MAX_REISSUES {
			tries.standard.next()
		} else {
			tries.slow.next()
		}))
	}

	fn failed(&self, error: &RoomsError, tries: &mut Tries) -> Result<Next, Error> {
		self.log(&format!("sending to {}: {error}", self.line.conversation));
		// A refused send refuses this line, not the bot's access.
		if error.kind == RoomsErrorKind::Refused {
			self.env.facts.borrow_mut().failed(Activity::Sending, error);
		} else {
			self.env.access_failed(Activity::Sending, error);
		}
		self.env.publish();
		Ok(match error.kind {
			RoomsErrorKind::Refused => {
				return self.abandon(&format!("the session refused my reply ({})", error.message));
			}
			RoomsErrorKind::Paused | RoomsErrorKind::Revoked => Next::After(tries.slow.next()),
			RoomsErrorKind::Unreachable | RoomsErrorKind::Uncertain | RoomsErrorKind::Exists => {
				let wait = tries.standard.next();
				Next::After(error.retry_after.map_or(wait, |advised| advised.max(wait)))
			}
		})
	}

	/// Replace the lines not yet sent with one failure line. When the lines
	/// were the failure line already, close the turn instead.
	fn abandon(&self, reason: &str) -> Result<Next, Error> {
		match self.content {
			Content::Answer => {
				let part = failure_part(reason)?;
				self.env.ledger.borrow_mut().fail_rest(self.env.store, self.id, part)?;
				Ok(Next::Now)
			}
			Content::Failure => {
				self.log(&format!("the failure line could not be sent either: {reason}"));
				finish(self.env, self.id, self.line.conversation)?;
				Ok(Next::Finished)
			}
		}
	}
}

/// A call to the session, failed as unreachable when it outlasts `limit`.
async fn within<T>(limit: Duration, call: impl Future<Output = Result<T, RoomsError>>) -> Result<T, RoomsError> {
	timeout(limit, call).await.unwrap_or_else(|_| Err(late()))
}

fn late() -> RoomsError {
	RoomsError::new(RoomsErrorKind::Unreachable, "the session did not answer in time")
}

/// Close the turn in the ledger and remove the files it saved.
fn finish<R: Rooms>(env: &Env<'_, R>, id: TurnId, conversation: &ConversationId) -> Result<(), Error> {
	env.ledger.borrow_mut().done(env.store, id)?;
	inbox::remove(env.store, conversation, id);
	Ok(())
}
