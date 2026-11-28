//! What the loop does with one batch of events: number each event, skip the
//! ones a turn already took, note who was heard from, keep context, and queue
//! triggers with the cursor a restart would read from to see them again.
//! [`admit`] then makes them turns in the ledger, so a restart neither loses
//! nor repeats them.
use super::{
	Env, Loop, Read,
	lanes::{Lanes, Queued},
};
use crate::bot::{
	classify::{self, Class, ContextLine},
	context,
	error::Error,
	gate::{Decision, Gate},
	ledger::{Asked, Ledger, TurnId},
	rooms::{Batch, ConversationId, Rooms},
	store::Store,
};
use std::collections::{BTreeMap, BTreeSet};

pub fn take<R: Rooms>(state: &mut Loop<'_, R>, batch: Batch) {
	let env = state.env;
	report_losses(env, &batch);
	let mut before = state.read.cursor.clone();
	let mut seq = state.read.seq;
	let mut context: BTreeMap<ConversationId, Vec<ContextLine>> = BTreeMap::new();
	let mut heard = BTreeSet::new();
	for event in &batch.events {
		let this = seq;
		seq = seq.next();
		let covered = env.ledger.borrow().covers(&event.cursor);
		if !covered {
			match classify::classify(event, this) {
				Class::Ignore => {}
				Class::Malformed(reason) => env
					.store
					.log(&format!("skipped an event in {}: {reason}", event.conversation)),
				Class::Context(line) => {
					heard.insert(event.conversation.clone());
					context.entry(event.conversation.clone()).or_default().push(line);
				}
				Class::Trigger(trigger) => {
					heard.insert(event.conversation.clone());
					state.lanes.queue(
						&event.conversation,
						Queued {
							trigger,
							kind: event.kind,
							before: before.clone(),
						},
					);
				}
			}
		}
		before = event.cursor.clone();
	}
	state.read = Read {
		cursor: batch.cursor,
		seq,
	};
	keep_context(state, &heard, context);
	state.publish();
}

/// Count and log what the session could not give in full.
fn report_losses<R: Rooms>(env: &Env<'_, R>, batch: &Batch) {
	if batch.gap {
		env.facts.borrow_mut().gaps += 1;
		env.store
			.log("the session no longer held some events and resumed past them");
	}
	if batch.unavailable {
		env.facts.borrow_mut().unavailable += 1;
		env.store.log("the session could not present some events");
	}
	if batch.unreadable > 0 {
		env.facts.borrow_mut().unreadable += batch.unreadable as u64;
		env.store.log(&format!(
			"skipped {} event(s) whose rows could not be read",
			batch.unreadable
		));
	}
}

/// Record the conversations heard and append the context lines, within the
/// bound on the conversations the bot keeps.
fn keep_context<R: Rooms>(
	state: &Loop<'_, R>,
	heard: &BTreeSet<ConversationId>,
	mut context: BTreeMap<ConversationId, Vec<ContextLine>>,
) {
	let env = state.env;
	// A conversation whose triggers wait for room in the ledger is as open
	// as one with a turn, so the bound never lets it go.
	let mut open = env.ledger.borrow().open_conversations();
	open.extend(state.lanes.waiting_conversations().cloned());
	let noted = env
		.conversations
		.borrow_mut()
		.heard(env.store, &mut env.harness_sessions.borrow_mut(), &open, heard);
	if let Err(error) = noted {
		// tolerant: until the bound holds again, these lines are not kept as
		// context, so no conversation's state grows past it. The next batch
		// tries to let the oldest conversation go again.
		env.store
			.log(&format!("letting go of conversations past the bound: {error}"));
		context.clear();
	}
	for (conversation, lines) in context {
		if let Err(error) = context::append(env.store, &conversation, lines) {
			// tolerant: context is advice for the harness, so a ring that
			// cannot be written loses these lines and the turn goes on.
			env.store.log(&format!("keeping context for {conversation}: {error}"));
		}
	}
}

/// Apply each decision in event order. A paid request joins the newest
/// unstarted turn with room. A refusal either opens a separate delivery or
/// moves past an event already covered by this window's notice.
pub fn admit<R: Rooms>(state: &mut Loop<'_, R>) -> Result<(), Error> {
	hold(
		&mut state.lanes,
		&mut state.env.ledger.borrow_mut(),
		state.env.store,
		&mut state.gate,
		&mut state.unsent,
	)
}

fn hold(
	lanes: &mut Lanes,
	ledger: &mut Ledger,
	store: &Store,
	gate: &mut Gate,
	sends: &mut Vec<(TurnId, ConversationId, super::Stage)>,
) -> Result<(), Error> {
	while let Some(unheld) = lanes.oldest_unheld() {
		let trigger = unheld.trigger;
		ledger.durable(store)?;
		let conversation = unheld.conversation;
		match gate.decide(store, &conversation, &trigger, ledger.cursor_seq())? {
			Decision::Start => {
				let id = match unheld.newest {
					Some(id) if ledger.room_in(id) > 0 => {
						ledger.extend(store, id, vec![trigger])?;
						id
					}
					_ if ledger.has_room() => ledger.begin(
						store,
						Asked {
							conversation: conversation.clone(),
							kind: unheld.kind,
							triggers: vec![trigger],
						},
					)?,
					_ => break,
				};
				lanes.held(&conversation, 1, id);
			}
			Decision::Notify(until) => {
				if !ledger.has_room() {
					break;
				}
				let id = ledger.notice(store, conversation.clone(), &trigger, until)?;
				store.log(&format!(
					"hourly limit in {conversation}: skipped an addressed request; retry at {}",
					crate::bot::stamp::rfc3339(until)
				));
				lanes.refused(&conversation);
				sends.push((id, conversation, super::Stage::Notice));
			}
			Decision::Skip => {
				ledger.advance(store, &trigger.event, trigger.seq.next())?;
				lanes.refused(&conversation);
			}
		}
	}
	Ok(())
}

#[cfg(test)]
mod tests;
