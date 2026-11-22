//! What the loop does with one batch of events: number each event, skip the
//! ones a turn already took, note who was heard from, keep context, and queue
//! triggers with the cursor a restart would read from to see them again. [`admit`] then makes them
//! turns in the ledger, so a restart neither loses nor repeats them.
use super::{Loop, Read, lanes::Queued};
use crate::bot::{
	classify::{self, Class, ContextLine, Trigger},
	context,
	error::Error,
	gate::Declined,
	ledger::Asked,
	rooms::{Batch, ConversationId, Rooms},
};
use std::collections::{BTreeMap, BTreeSet};
use tokio::time::Instant;

pub fn take<R: Rooms>(state: &mut Loop<'_, R>, batch: Batch) {
	let env = state.env;
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
	let mut before = state.read.cursor.clone();
	let mut seq = state.read.seq;
	let mut context: BTreeMap<ConversationId, Vec<ContextLine>> = BTreeMap::new();
	let mut heard = BTreeSet::new();
	let policy = env.config.policy();
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
				// A line from someone off the allow list never reaches the
				// agent, and never counts as the conversation being heard
				// from, so it cannot push out anyone else's state.
				Class::Context(_) if !policy.admits(classify::sender(event)) => {}
				Class::Context(line) => {
					heard.insert(event.conversation.clone());
					context.entry(event.conversation.clone()).or_default().push(line);
				}
				Class::Trigger(trigger) => {
					let sender = classify::sender(event);
					match state.gate.trigger(&policy, &event.conversation, sender, Instant::now()) {
						Ok(()) => {
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
						Err(Declined::NotAllowed) => env.store.log(&format!(
							"ignored a message in {}: {}",
							event.conversation,
							Declined::NotAllowed.reason()
						)),
						Err(declined) => {
							heard.insert(event.conversation.clone());
							env.store.log(&format!(
								"kept a message in {} as context without a reply: {}",
								event.conversation,
								declined.reason()
							));
							context
								.entry(event.conversation.clone())
								.or_default()
								.push(kept(trigger));
						}
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
	// A conversation whose triggers wait for room in the ledger is as open
	// as one with a turn, so the bound never lets it go.
	let mut open = env.ledger.borrow().open_conversations();
	open.extend(state.lanes.waiting_conversations().cloned());
	let noted = env
		.conversations
		.borrow_mut()
		.heard(env.store, &mut env.sessions.borrow_mut(), &open, &heard);
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
	state.publish();
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
/// the cursor stays before.
pub fn admit<R: Rooms>(state: &mut Loop<'_, R>) -> Result<(), Error> {
	let env = state.env;
	while let Some(unheld) = state.lanes.oldest_unheld() {
		let room = unheld.newest.map_or(0, |id| env.ledger.borrow().room_in(id));
		let (id, count) = match unheld.newest {
			Some(id) if room > 0 => {
				let count = room.min(unheld.triggers.len());
				let mut triggers = unheld.triggers;
				triggers.truncate(count);
				env.ledger.borrow_mut().extend(env.store, id, triggers)?;
				(id, count)
			}
			_ if env.ledger.borrow().has_room() => {
				let count = unheld.triggers.len();
				let asked = Asked {
					conversation: unheld.conversation.clone(),
					kind: unheld.kind,
					triggers: unheld.triggers,
				};
				(env.ledger.borrow_mut().begin(env.store, asked)?, count)
			}
			_ => break,
		};
		state.lanes.held(&unheld.conversation, count, id);
	}
	Ok(())
}
