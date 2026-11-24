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
	classify::{self, Class, ContextLine, Trigger},
	context,
	error::Error,
	ledger::{Asked, Ledger},
	rooms::{Batch, ConversationId, Rooms},
	store::Store,
	words,
};
use std::collections::{BTreeMap, BTreeSet};
use tokio::time::Instant;

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
					if state.gate.starts_work(&event.conversation, Instant::now()) {
						state.lanes.queue(
							&event.conversation,
							Queued {
								trigger,
								kind: event.kind,
								before: before.clone(),
							},
						);
					} else {
						env.store.log(&words::context_only(&event.conversation.to_string()));
						context
							.entry(event.conversation.clone())
							.or_default()
							.push(kept(trigger));
					}
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

/// A trigger the gate turned away, as the context it becomes.
fn kept(trigger: Trigger) -> ContextLine {
	ContextLine {
		seq: trigger.seq,
		event: trigger.event,
		from: trigger.from,
		text: trigger.text,
	}
}

/// Hold every queued trigger in a turn, oldest first: in the conversation's
/// newest turn that has not started while it has room, or in a new turn.
/// Admission stops at the first trigger the ledger has no room for, so no
/// trigger is held ahead of an older one, and the one that waits is the one
/// the cursor stays before. Each batch is older than every other unheld
/// trigger ([`Lanes::oldest_unheld`](super::lanes::Lanes::oldest_unheld)), so
/// every held trigger is older than every unheld one.
pub fn admit<R: Rooms>(state: &mut Loop<'_, R>) -> Result<(), Error> {
	hold(&mut state.lanes, &mut state.env.ledger.borrow_mut(), state.env.store)
}

fn hold(lanes: &mut Lanes, ledger: &mut Ledger, store: &Store) -> Result<(), Error> {
	while let Some(unheld) = lanes.oldest_unheld() {
		let room = unheld.newest.map_or(0, |id| ledger.room_in(id));
		let (id, count) = match unheld.newest {
			Some(id) if room > 0 => {
				let count = room.min(unheld.triggers.len());
				let mut triggers = unheld.triggers;
				triggers.truncate(count);
				ledger.extend(store, id, triggers)?;
				(id, count)
			}
			_ if ledger.has_room() => {
				let count = unheld.triggers.len();
				let asked = Asked {
					conversation: unheld.conversation.clone(),
					kind: unheld.kind,
					triggers: unheld.triggers,
				};
				(ledger.begin(store, asked)?, count)
			}
			_ => break,
		};
		lanes.held(&unheld.conversation, count, id);
	}
	Ok(())
}

#[cfg(test)]
mod tests;
