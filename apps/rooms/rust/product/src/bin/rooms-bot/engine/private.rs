//! A direct reply can use a privately posted question only while it holds
//! that exact route. Save the fence in the turn before the model sees text.
use super::*;
use crate::bot::{
	direct_context::{self, Speech},
	ledger::Asked,
};

pub(super) fn prepare<R: Rooms>(env: &Env<'_, R>, id: TurnId, asked: &Asked) -> Result<bool, Error> {
	if asked.kind != crate::bot::rooms::Kind::Direct || env.ledger.borrow().scheduled(id).is_some() {
		return Ok(true);
	}
	if let Some(known) = env.ledger.borrow().private_speech(id) {
		if let Some(operation) = &known.operation {
			direct_context::claim(env.store.root(), operation, id)?;
		}
		return Ok(true);
	}
	let Some(first) = asked.triggers.first() else {
		return Ok(false);
	};
	let Some(scope) = &first.scope else {
		// Old pending DMs did not persist their receiving route. A native
		// attachment cannot safely send their reply to a reused id.
		return Ok(!env.rooms.requires_direct_scope());
	};
	if asked
		.triggers
		.iter()
		.any(|trigger| trigger.scope.as_ref() != Some(scope))
	{
		return Ok(false);
	}
	let previous = if super::reset::last(asked).is_some() {
		direct_context::reset(env.store.root(), scope)?;
		None
	} else {
		direct_context::latest(env.store.root(), scope, first.seq, id)?
	};
	let speech = previous.unwrap_or_else(|| Speech::bound(scope.clone()));
	let operation = speech.operation.clone();
	env.ledger.borrow_mut().bind_private(env.store, id, speech)?;
	if let Some(operation) = operation {
		direct_context::claim(env.store.root(), &operation, id)?;
	}
	Ok(true)
}

pub(super) fn pending(ledger: &Ledger, id: TurnId) -> bool {
	ledger.private_speech(id).is_none()
		&& matches!(ledger.phase(id),Some(Phase::Running {asked,..})
        if asked.triggers.iter().any(|trigger| trigger.opening_until.is_some()))
}

/// An unresolved direct turn owns only its bounded ledger row and its lane.
/// Ready room and DM turns can use both harness slots throughout the wait.
pub(super) async fn opening<R: Rooms>(
	env: &Env<'_, R>,
	id: TurnId,
	stop: &mut watch::Receiver<bool>,
) -> Result<Step, Error> {
	let Some(Phase::Running { asked, .. }) = env.ledger.borrow().phase(id).cloned() else {
		return Err(Ledger::invariant("an opening direct turn is absent"));
	};
	let first = asked
		.triggers
		.first()
		.ok_or_else(|| Ledger::invariant("opening without a message"))?;
	let scope = first
		.scope
		.as_ref()
		.ok_or_else(|| Ledger::invariant("opening without a scope"))?;
	let until = asked
		.triggers
		.iter()
		.filter_map(|trigger| trigger.opening_until)
		.min()
		.ok_or_else(|| Ledger::invariant("opening without a deadline"))?;
	let events = asked
		.triggers
		.iter()
		.filter(|trigger| trigger.opening_until.is_some())
		.map(|trigger| trigger.event.clone())
		.collect::<Vec<_>>();
	if asked
		.triggers
		.iter()
		.all(|trigger| trigger.scope.as_ref() == Some(scope))
	{
		match wait_for_route(env, scope, &events, until, stop).await {
			None => return Ok(Step::Stopped),
			Some(true) if prepare(env, id, &asked)? => return Ok(Step::Ready),
			_ => {}
		}
	}
	closed(env, id)
}

fn closed<R: Rooms>(env: &Core<'_, R>, id: TurnId) -> Result<Step, Error> {
	env.ledger.borrow_mut().done(env.store, id)?;
	env.store.log(&format!(
		"turn {} ended because its original direct return route was unavailable",
		id.0
	));
	Ok(Step::Finished)
}

pub(super) async fn notice<R: Rooms>(
	env: &Core<'_, R>,
	id: TurnId,
	stop: &mut watch::Receiver<bool>,
) -> Result<Option<Step>, Error> {
	use crate::bot::{gate, ledger::Attempt};
	let pending = {
		let ledger = env.ledger.borrow();
		let Some(Phase::Sending {
			content: Content::Availability,
			covered,
			conversation,
			attempt: Attempt::Unsent,
			..
		}) = ledger.phase(id)
		else {
			return Ok(None);
		};
		let Some(until) = covered.opening_until else {
			return Ok(None);
		};
		let scope = ledger
			.scope(id)
			.cloned()
			.ok_or_else(|| Ledger::invariant("opening notice without a scope"))?;
		(scope, conversation.clone(), covered.events.clone(), until)
	};
	let (scope, conversation, events, until) = pending;
	match wait_for_route(env, &scope, &events, until, stop).await {
		Some(true) => Ok(None),
		None => Ok(Some(Step::Stopped)),
		Some(false) => {
			if let Some(event) = events.first() {
				gate::observed(env.store, &conversation, event, gate::Notice::Refused)?;
			}
			closed(env, id).map(Some)
		}
	}
}

/// The saved wall-clock deadline survives restart. The process uses a
/// monotonic deadline for all its reads and sleeps. On recovery after expiry,
/// one bounded read can prove the original route is already held.
async fn wait_for_route<R: Rooms>(
	env: &Core<'_, R>,
	scope: &crate::bot::rooms::Scope,
	events: &[Cursor],
	until: u64,
	stop: &mut watch::Receiver<bool>,
) -> Option<bool> {
	use crate::bot::rooms::{Opening, RoomsErrorKind};
	let budget = Duration::from_millis(rooms_application::direct::RECIPROCAL_ROUTE_TIMEOUT_MS);
	let remaining = Duration::from_secs(until.saturating_sub(crate::bot::stamp::seconds())).min(budget);
	let deadline = Instant::now() + if remaining.is_zero() { budget } else { remaining };
	let mut backoff = Backoff::standard();
	loop {
		let state = tokio::select! {
			biased;
			()=stopping(stop)=>return None,
			state=tokio::time::timeout_at(deadline,env.rooms.opening(scope,events))=>state,
		};
		match state {
			Ok(Ok(Opening::Held)) => return Some(true),
			Err(_)
			| Ok(Ok(Opening::Gone))
			| Ok(Err(RoomsError {
				kind: RoomsErrorKind::Refused | RoomsErrorKind::Revoked,
				..
			})) => return Some(false),
			Ok(Ok(Opening::Pending)) => {}
			Ok(Err(cause)) => env.access_failed(Activity::Thinking, &cause),
		}
		if remaining.is_zero() || Instant::now() >= deadline {
			return Some(false);
		}
		let delay = deadline.saturating_duration_since(Instant::now()).min(backoff.next());
		if !waited(delay, stop).await {
			return None;
		}
	}
}
