//! A clock occurrence enters the same bounded conversation lane as a message.
//! Admission and the occurrence identity reach disk together before the clock
//! receives an acknowledgement. A scheduled turn never covers an inbox event.
use super::*;
use crate::bot::{
	gate::ScheduledDecision,
	ledger::Scheduled,
	reminders::{self, Admission, CheckIn},
	rooms::Scope,
	rooms::{Base, RoomsErrorKind},
};

pub(super) async fn accept<R: Rooms>(state: &mut Loop<'_, R>, check: CheckIn) -> Result<(), Error> {
	let CheckIn {
		scope,
		operation,
		task,
		reply,
	} = check;
	let env = state.env;
	let admit = || -> Result<Admission, Error> {
		let mut ledger = env.ledger.borrow_mut();
		Ok(if ledger.admitted(&operation) {
			ledger.durable(env.store)?;
			Admission::Admitted
		} else if !state.may_think() || state.held.is_some() || !ledger.has_room() {
			Admission::Busy
		} else {
			let pending = reminders::pending_check_ins(env.store.root())?;
			let conversation = ConversationId::new(scope.conversation());
			if !pending.admitting.contains(&operation) {
				return Ok(Admission::Refused);
			}
			match state
				.gate
				.scheduled(env.store, &conversation, &operation, &pending.live, ledger.cursor_seq())?
			{
				ScheduledDecision::RetryAt { until, limit } => return Ok(Admission::HourlyLimit { until, limit }),
				ScheduledDecision::Start => {}
			}
			let mut open = ledger.open_conversations();
			open.extend(state.lanes.waiting_conversations().cloned());
			env.conversations.borrow_mut().heard(
				env.store,
				&mut env.harness_sessions.borrow_mut(),
				&open,
				&BTreeSet::from([conversation.clone()]),
			)?;
			let id = ledger.begin_scheduled(env.store, Scheduled { scope, operation, task }, &pending.admitting)?;
			state.lanes.resume(&conversation, id, Left::Waiting);
			ledger.durable(env.store)?;
			Admission::Admitted
		})
	};
	let result = match admit() {
		Ok(result) => result,
		Err(error) if error.is_transient() => {
			state.hold(&error);
			return Ok(());
		}
		Err(error) => return Err(error),
	};
	// A lost acknowledgement is safe: the clock retains the same operation.
	let _ = reply.send(result);
	Ok(())
}

pub(super) async fn base<R: Rooms>(env: &Core<'_, R>, scope: &Scope) -> Result<Option<Base>, RoomsError> {
	deliver::within(READ_DEADLINE, env.rooms.scoped_base(scope)).await
}

/// A transient outage must not turn a scheduled task into a failure message
/// to whichever membership happens to occupy its old conversation.
pub(super) async fn before_thinking<R: Rooms>(
	env: &Env<'_, R>,
	id: TurnId,
	stop: &mut watch::Receiver<bool>,
) -> Result<Option<Step>, Error> {
	let scope = env.ledger.borrow().scope(id).cloned();
	let Some(scope) = scope else { return Ok(None) };
	let mut backoff = Backoff::standard();
	loop {
		let current = tokio::select! {
			biased;
			()=stopping(stop)=>return Ok(Some(Step::Stopped)),
			checked=base(env,&scope)=>checked,
		};
		match current {
			Ok(Some(_)) => return Ok(None),
			Ok(None)
			| Err(RoomsError {
				kind: RoomsErrorKind::Refused,
				..
			}) => {
				env.ledger.borrow_mut().done(env.store, id)?;
				env.store.log(&format!(
					"turn {} ended because its original destination is unavailable",
					id.0
				));
				return Ok(Some(Step::Finished));
			}
			Err(error) => {
				env.access_failed(Activity::Thinking, &error);
				if !waited(error.retry_after.unwrap_or_default().max(backoff.next()), stop).await {
					return Ok(Some(Step::Stopped));
				}
			}
		}
	}
}
