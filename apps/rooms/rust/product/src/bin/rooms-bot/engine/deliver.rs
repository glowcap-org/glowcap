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
//! operation at a fresh base. A resend refused any other way is looked at
//! again, and becomes a failure line only once a look finds no receipt and a
//! complete read finds no echo. Whenever activity cannot tell, the line is
//! given up on without sending it again, and `status` counts it as
//! unconfirmed.
//!
//! Every receipt this access holds that delivery stops caring about is kept
//! or released, so none is left to fill the session. A line settled without
//! being kept is recorded first, so a restart before its release finishes the
//! release and never sends the line. A line another access sent goes in the
//! ledger as a replaced line (`ledger/replaced.rs`), and `replaced.rs` keeps
//! or releases its receipt when a start finds this access holds it again.
//! Delivery does not give up on a session that is unreachable or paused,
//! because giving up would leave a trigger with no reply while the session may
//! still hold part of it. The wait and the failure reach `status`. A first
//! send the session refused before dispatching it, as a full receipt window
//! does, waits with no operation sent and then goes out under a new one.
//!
//! A reply goes out only while the access is active, so delivery waits while
//! the session reads it as paused or revoked (`env::access_of`), and no reply
//! resumes before the link is reached.
//!
//! A line another access sent is in [`Core::by_echo`] and is decided by its
//! echo alone, as `serve/access.rs` describes.
//!
//! This file owns the step machine. Its `pace` module owns the bounds, the
//! waits, and the deadline on a call, its `receipt` module reads the
//! session's answers about one receipt, and its `replaced` module settles the
//! replaced lines a start finds this access holds again.
mod pace;
pub mod receipt;
pub(super) use pace::within;
mod replaced;
use super::{Core, Step, failure_part};
use crate::bot::words::{self, CANNOT_SAY_WHETHER, MOVED_ON, NO_RECEIPT, NOT_KEPT, SENDING_UNDER_NEW};
use crate::bot::{
	error::Error,
	fault::{self, Fail, Kill},
	gate::{self, Notice},
	inbox,
	ledger::{Attempt, Content, Ledger, Phase, Replaced, TurnId},
	rooms::{
		Base, ConversationId, Cursor, Echo, Outcome, Outgoing, READ_DEADLINE, Rooms, RoomsError, RoomsErrorKind,
		SEND_DEADLINE,
	},
	status::{Access, Activity},
};
use pace::{ACCESS_POLL, Call, MAX_LOOKS, MAX_REISSUES, Mode, Next, Tries, late};
use receipt::{Given, Left, Look, Receipt};
pub use replaced::settle as settle_replaced;
use tokio::sync::watch;

pub async fn run<R: Rooms>(env: &Core<'_, R>, id: TurnId, stop: &mut watch::Receiver<bool>) -> Result<Step, Error> {
	drive(env, id, stop, Mode::Deliver).await
}

/// Settle the line of turn `id` that is already sent, and stop before
/// sending another. A line the session refused as a conflict stops there too,
/// to go out under a new operation later.
pub async fn settle_sent<R: Rooms>(
	env: &Core<'_, R>,
	id: TurnId,
	stop: &mut watch::Receiver<bool>,
) -> Result<Step, Error> {
	drive(env, id, stop, Mode::SettleSent).await
}

/// Whether turn `id` has a line this access sent, or is about to send, that is
/// not settled. A line the session says another access sent is that access's.
pub fn sent_unsettled<R: Rooms>(env: &Core<'_, R>, id: TurnId) -> bool {
	let ledger = env.ledger.borrow();
	let Some(Phase::Sending {
		parts, sent, attempt, ..
	}) = ledger.phase(id)
	else {
		return false;
	};
	attempt.is_sent()
		&& parts
			.get(*sent)
			.is_some_and(|part| !env.by_echo.contains(&part.operation))
}

async fn drive<R: Rooms>(
	env: &Core<'_, R>,
	id: TurnId,
	stop: &mut watch::Receiver<bool>,
	mode: Mode,
) -> Result<Step, Error> {
	let mut tries = Tries::new();
	loop {
		if *stop.borrow() {
			return Ok(Step::Stopped);
		}
		if mode == Mode::SettleSent && !sent_unsettled(env, id) {
			return Ok(Step::Finished);
		}
		// A reply goes out only while the access is active, as a new turn
		// starts only then. A refusal under an access the session has not
		// accepted would give the reply up.
		if mode == Mode::Deliver && env.facts.borrow().access != Access::Active {
			if !super::waited(ACCESS_POLL, stop).await {
				return Ok(Step::Stopped);
			}
			continue;
		}
		match step(env, id, &mut tries).await? {
			Next::Finished => return Ok(Step::Finished),
			Next::Now => {}
			Next::Access => {
				if let Some(wait) = mode.access_wait(&mut tries.slow)
					&& !super::waited(wait, stop).await
				{
					return Ok(Step::Stopped);
				}
			}
			Next::After(wait) => {
				if fault::held_retry(env.store.root(), stop).await {
					continue;
				}
				if !super::waited(wait, stop).await {
					return Ok(Step::Stopped);
				}
			}
		}
	}
}

/// One call to the session for the next line, and the ledger change it earns.
async fn step<R: Rooms>(env: &Core<'_, R>, id: TurnId, tries: &mut Tries) -> Result<Next, Error> {
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
	let turn = Delivery {
		env,
		id,
		content,
		line,
		began,
	};
	if let Some(base) = attempt.base()
		&& env.by_echo.contains(&part.operation)
	{
		return match attempt {
			Attempt::Sent { after, .. } => turn.by_echo(&after, base, tries).await,
			// A committed line posted. A line given up on, which `Releasing`
			// also records, may never have.
			Attempt::Releasing { .. } => turn.leave("was given up on", base, tries),
			_ => turn.leave("posted", base, tries),
		};
	}
	match attempt {
		Attempt::Unsent => {
			let scope = env.ledger.borrow().scheduled(id).map(|s| s.scope.clone());
			let checked = match scope {
				Some(scope) => super::checkins::base(env, &scope).await,
				None => within(SEND_DEADLINE, env.rooms.base()).await.map(Some),
			};
			let base = match checked {
				Ok(Some(base)) => base,
				Ok(None) => {
					env.store.log(&format!(
						"scheduled turn {} closed before posting to a changed destination",
						id.0
					));
					finish(env, id, &conversation)?;
					return Ok(Next::Finished);
				}
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
			// The base is the commit point, so it is on disk before the send.
			env.ledger.borrow_mut().durable(env.store)?;
			fault::hit(Kill::BeforeSend);
			let answer = match within(SEND_DEADLINE, env.rooms.send(&line, base)).await {
				Ok(_) if fault::fails(Fail::LateSend) => Err(late()),
				answer => answer,
			};
			fault::hit(Kill::AfterSend);
			turn.answered(answer, Call::FirstSend, base, after, 0, tries).await
		}
		Attempt::Sent { base, after, looks, .. } => {
			let (answer, call) = if let Some(call) = tries.again.take() {
				let scope = env.ledger.borrow().scheduled(id).map(|s| s.scope.clone());
				if let Some(scope) = scope {
					match super::checkins::base(env, &scope).await {
						Ok(Some(_)) => {}
						Ok(None) => return turn.give_up(base),
						Err(error) => return turn.failed(&error, tries),
					}
				}
				let answer = within(SEND_DEADLINE, env.rooms.send(&line, base)).await;
				fault::hit(Kill::AfterSend);
				(answer, call)
			} else {
				match receipt::look(env, &line, base).await {
					Look::Seen(outcome) => (Ok(outcome), Call::Observe),
					Look::Refused => return turn.give_up(base),
					Look::Failed(error) => (Err(error), Call::Observe),
				}
			};
			turn.answered(answer, call, base, after, looks, tries).await
		}
		Attempt::Committed { base } => turn.keep(base, tries).await,
		Attempt::Releasing { base } => turn.release(base, tries).await,
	}
}

/// The line of one turn being sent, as one step handles it.
struct Delivery<'e, 'l, R: Rooms> {
	env: &'e Core<'e, R>,
	id: TurnId,
	content: Content,
	line: Outgoing<'l>,
	/// The access changes counted when this step began.
	began: u64,
}

impl<R: Rooms> Delivery<'_, '_, R> {
	fn notice(&self, state: Notice) -> Result<(), Error> {
		if self.content == Content::Availability
			&& let Some(Phase::Sending { covered, .. }) = self.env.ledger.borrow().phase(self.id)
			&& let Some(event) = covered.events.first()
		{
			gate::observed(self.env.store, self.line.conversation, event, state)?;
		}
		Ok(())
	}

	fn log(&self, what: &str) {
		self.env.store.log(&format!("turn {}: {what}", self.id.0));
	}

	/// Act on what a send or a look at it answered.
	async fn answered(
		&self,
		answer: Result<Outcome, RoomsError>,
		call: Call,
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
				// The operation did not post, so a refusal of its resend is now
				// the session's answer for the line.
				Ok(Echo::NotFound) if let Some(refused) = tries.refused_resend.take() => {
					self.env.facts.borrow_mut().failed(Activity::Sending, &refused);
					self.env.publish();
					self.abandon(&format!("the session refused my reply ({})", refused.message), tries)
				}
				Ok(Echo::NotFound) => {
					self.log(&format!(
						"{NO_RECEIPT} {} and activity shows no echo. Sending it again at its base",
						self.line.operation
					));
					tries.again = Some(Call::Resend);
					Ok(Next::Now)
				}
				Ok(Echo::Restarted | Echo::Unknowable) => self.give_up(base),
				Err(error) => self.failed(&error, tries),
			},
			Ok(Outcome::Conflict) => match call {
				Call::FirstSend | Call::Observe => self.conflict(tries),
				Call::Resend => match self.echo(&after).await {
					Ok(Echo::Found) => self.committed(base, tries),
					Ok(Echo::NotFound) => self.conflict(tries),
					Ok(Echo::Restarted | Echo::Unknowable) => self.give_up(base),
					Err(error) => self.failed(&error, tries),
				},
			},
			// A refusal that proves nothing was dispatched is never looked at
			// into a give-up. A first send went nowhere, so the line waits with
			// no operation sent and goes out under a new one at a fresh base,
			// and a session restart during the wait changes nothing.
			Err(error) if call == Call::FirstSend && error.refused_before_dispatch => {
				self.env.ledger.borrow_mut().reissue(
					self.env.store,
					self.id,
					crate::bot::identity::new_action(self.env.store.root())?,
				)?;
				self.failed(&error, tries)
			}
			// A refused resend, whatever the code, says nothing of the earlier
			// send of its operation, which may still commit. The line goes on
			// as after an uncertain send: it waits and is looked at again at
			// its base, and is never replaced or failed on this answer. A
			// refusal that waiting will not clear is kept, and the failure line
			// goes out only once a look finds no receipt and a complete read
			// finds no echo. A refusal of the access is handled as for any call.
			Err(error)
				if call == Call::Resend && (error.refused_before_dispatch || error.kind == RoomsErrorKind::Refused) =>
			{
				if error.kind == RoomsErrorKind::Refused {
					tries.refused_resend = Some(error.clone());
				}
				let uncertain = RoomsError {
					kind: RoomsErrorKind::Uncertain,
					..error
				};
				self.failed(&uncertain, tries)
			}
			Err(error) => self.failed(&error, tries),
		}
	}

	/// Record the commit, so a crash before the line is kept keeps it later.
	fn committed(&self, base: Base, tries: &mut Tries) -> Result<Next, Error> {
		self.notice(Notice::Posted)?;
		self.env
			.ledger
			.borrow_mut()
			.attempt(self.env.store, self.id, Attempt::Committed { base })?;
		fault::hit(Kill::AfterCommit);
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
					"a line to {} posted, but {NOT_KEPT}: {error}. Releasing its receipt",
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
		fault::hit(Kill::AfterRecord);
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
	/// the next. A session that does not answer, asks for a wait, or still runs
	/// the line's executor within its running bound is asked again later. A
	/// receipt the session refuses to take back is recorded in the ledger when
	/// it still holds a place (`receipt::leave`), and logged once the line is
	/// recorded as sent (`receipt::left`).
	async fn release(&self, base: Base, tries: &mut Tries) -> Result<Next, Error> {
		let refused =
			match receipt::give_back(self.env.rooms, Receipt::Line(&self.line, base), &mut tries.running).await {
				Given::Back => {
					fault::hit(Kill::AfterRelease);
					None
				}
				Given::Left(error) => match receipt::leave(self.env, &self.line, base).await {
					Ok(()) => Some(error),
					Err(Left::Looking(error)) => return self.failed(&error, tries),
					Err(Left::Saving(error)) => return Err(error),
				},
				Given::Running => return Ok(Next::After(tries.standard.next())),
				Given::Failed(error) => return self.failed(&error, tries),
			};
		let next = self.settled(tries)?;
		if let Some(error) = refused {
			receipt::left(self.env, self.line.operation, &error);
		}
		Ok(next)
	}

	/// Settle a line nobody can confirm, without sending it again, because a
	/// second send could post it twice. Its receipt is released next.
	fn give_up(&self, base: Base) -> Result<Next, Error> {
		self.notice(Notice::Unconfirmed)?;
		self.releasing(base)?;
		self.unconfirmed(&format!(
			"the session {CANNOT_SAY_WHETHER} {} to {} posted. {MOVED_ON}",
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

	/// Settle a line another access sent and left unsettled by its echo alone,
	/// and record it as replaced. This access neither keeps, releases, nor
	/// sends the line again.
	async fn by_echo(&self, after: &Cursor, base: Base, tries: &mut Tries) -> Result<Next, Error> {
		let found = match self.echo(after).await {
			Ok(echo) => echo == Echo::Found,
			Err(error) => return self.failed(&error, tries),
		};
		self.notice(if found { Notice::Posted } else { Notice::Unconfirmed })?;
		let next = self.replaced(base, tries)?;
		if found {
			self.log_left("posted");
		} else {
			self.unconfirmed(&format!(
				"the session {} {}, {}, posted. {}",
				CANNOT_SAY_WHETHER,
				self.line.operation,
				words::NOT_SENT_HERE,
				MOVED_ON
			));
		}
		Ok(next)
	}

	/// Settle a line another access sent and committed, or owed a release, and
	/// record it as replaced.
	fn leave(&self, what: &str, base: Base, tries: &mut Tries) -> Result<Next, Error> {
		let next = self.replaced(base, tries)?;
		self.log_left(what);
		Ok(next)
	}

	/// Record the line settled and replaced in one write, then move to the
	/// next.
	fn replaced(&self, base: Base, tries: &mut Tries) -> Result<Next, Error> {
		let record = Replaced {
			operation: self.line.operation.to_owned(),
			base,
			conversation: self.line.conversation.clone(),
			text: self.line.text.to_owned(),
		};
		let dropped = self
			.env
			.ledger
			.borrow_mut()
			.part_replaced(self.env.store, self.id, record)?;
		if let Some(dropped) = dropped {
			self.log(&format!(
				"the session holds more receipts of lines another access sent than it has places, so the record of \
				 operation {} is dropped and its receipt stays until its access is revoked",
				dropped.operation
			));
		}
		fault::hit(Kill::AfterRecord);
		tries.settled();
		self.env.publish();
		Ok(Next::Now)
	}

	/// Log a line settled by its echo: what became of it, and that this access
	/// holds no receipt of it.
	fn log_left(&self, what: &str) {
		self.log(&format!(
			"operation {} {what}. {}, so its receipt stays with the access that sent it until that access keeps it or is \
			 revoked",
			self.line.operation,
			words::NO_RECEIPT_HELD
		));
	}

	fn conflict(&self, tries: &mut Tries) -> Result<Next, Error> {
		tries.ended();
		tries.reissues = tries.reissues.saturating_add(1);
		self.log(&format!(
			"the session committed nothing for operation {}. {SENDING_UNDER_NEW}",
			self.line.operation
		));
		self.env.ledger.borrow_mut().reissue(
			self.env.store,
			self.id,
			crate::bot::identity::new_action(self.env.store.root())?,
		)?;
		Ok(Next::After(if tries.reissues <= MAX_REISSUES {
			tries.standard.next()
		} else {
			tries.slow.next()
		}))
	}

	fn failed(&self, error: &RoomsError, tries: &mut Tries) -> Result<Next, Error> {
		self.log(&format!(
			"sending operation {} to {}: {error}",
			self.line.operation, self.line.conversation
		));
		// Only `Refused` is a verdict on this line. The rest are about the
		// access or the session, and the line waits for them.
		if error.kind == RoomsErrorKind::Refused {
			self.env.facts.borrow_mut().failed(Activity::Sending, error);
		} else {
			self.env.access_failed(Activity::Sending, error);
		}
		self.env.publish();
		Ok(match error.kind {
			RoomsErrorKind::Refused => {
				return self.abandon(&format!("the session refused my reply ({})", error.message), tries);
			}
			// The access state is recorded above. A paused access is waited out,
			// which `drive` paces, and a revoked or denied one ends serving.
			RoomsErrorKind::Paused | RoomsErrorKind::Revoked | RoomsErrorKind::Denied => Next::Access,
			RoomsErrorKind::Unreachable | RoomsErrorKind::Uncertain | RoomsErrorKind::Exists => {
				let wait = tries.standard.next();
				Next::After(error.retry_after.map_or(wait, |advised| advised.max(wait)))
			}
		})
	}

	/// Replace the lines not yet sent with one failure line. When the lines
	/// were the failure line already, close the turn instead.
	fn abandon(&self, reason: &str, tries: &mut Tries) -> Result<Next, Error> {
		tries.ended();
		match self.content {
			Content::Answer => {
				let part = failure_part(self.env, self.id, reason)?;
				self.env.ledger.borrow_mut().fail_rest(self.env.store, self.id, part)?;
				Ok(Next::Now)
			}
			Content::Failure | Content::Availability => {
				self.notice(Notice::Refused)?;
				self.log(&format!("the notice could not be sent: {reason}"));
				finish(self.env, self.id, self.line.conversation)?;
				Ok(Next::Finished)
			}
		}
	}
}

/// Close the turn in the ledger and remove the files it saved.
fn finish<R: Rooms>(env: &Core<'_, R>, id: TurnId, conversation: &ConversationId) -> Result<(), Error> {
	env.ledger.borrow_mut().done(env.store, id)?;
	inbox::remove(env.store, conversation, id);
	Ok(())
}
