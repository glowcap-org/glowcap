//! Per-conversation order. A lane is one conversation. Its triggers become
//! turns in the ledger as soon as they are read, in the order they were read
//! across every conversation, and the lane runs one of its turns at a time.
//! A trigger waits in memory only while the ledger has no room for another
//! turn, and the oldest such trigger is where the durable cursor stays.
//!
//! Every held trigger is older than every unheld one, because a batch takes a
//! conversation's triggers only while each is older than every other
//! conversation's oldest unheld trigger. So once the cursor moves to the
//! oldest unheld trigger, every finished turn lies before it and leaves the
//! ledger, and the oldest unheld trigger gets a turn as soon as the turns
//! older than it end. A restart reads again only the triggers after the
//! cursor that no turn covers, which are all newer than every held one.
use crate::bot::{
	classify::{Seq, Trigger},
	ledger::{MAX_TRIGGERS, TurnId},
	rooms::{ConversationId, Cursor, Kind},
};
use std::collections::{BTreeMap, VecDeque};

/// A trigger no turn holds, with the cursor just before its event, which is
/// where a restart would have to read from to see it again.
pub struct Queued {
	pub trigger: Trigger,
	pub kind: Kind,
	pub before: Cursor,
}

#[derive(Default)]
struct Lane {
	/// A turn of this conversation is thinking or delivering.
	busy: bool,
	/// Turns in the ledger that have not started, oldest first.
	turns: VecDeque<TurnId>,
	/// Triggers no turn holds yet, oldest first.
	waiting: VecDeque<Queued>,
}

/// The oldest triggers no turn holds, all from one conversation.
pub struct Unheld {
	pub conversation: ConversationId,
	pub kind: Kind,
	pub triggers: Vec<Trigger>,
	/// The conversation's newest turn that has not started, which may still
	/// take triggers.
	pub newest: Option<TurnId>,
}

/// Where a previous bot left a turn.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Left {
	/// Not started: it takes its place in the lane.
	Waiting,
	/// Delivering its reply: the lane is busy until it ends.
	Delivering,
}

#[derive(Default)]
pub struct Lanes(BTreeMap<ConversationId, Lane>);

impl Lanes {
	pub fn queue(&mut self, conversation: &ConversationId, queued: Queued) {
		self.0
			.entry(conversation.clone())
			.or_default()
			.waiting
			.push_back(queued);
	}

	/// The conversation whose oldest unheld trigger is oldest, with up to
	/// [`MAX_TRIGGERS`] of its unheld triggers that are older than every other
	/// conversation's oldest unheld trigger. Nothing changes until
	/// [`Lanes::held`].
	pub fn oldest_unheld(&self) -> Option<Unheld> {
		let (conversation, lane) = self
			.0
			.iter()
			.filter(|(_, lane)| !lane.waiting.is_empty())
			.min_by_key(|(_, lane)| lane.waiting.front().map(|first| first.trigger.seq))?;
		let first = lane.waiting.front()?;
		let next_elsewhere = self
			.0
			.iter()
			.filter(|(other, _)| *other != conversation)
			.filter_map(|(_, other)| other.waiting.front().map(|queued| queued.trigger.seq))
			.min();
		Some(Unheld {
			conversation: conversation.clone(),
			kind: first.kind,
			triggers: lane
				.waiting
				.iter()
				.take(MAX_TRIGGERS)
				.take_while(|queued| next_elsewhere.is_none_or(|next| queued.trigger.seq < next))
				.map(|queued| queued.trigger.clone())
				.collect(),
			newest: lane.turns.back().copied(),
		})
	}

	/// The first `count` unheld triggers are durable in turn `id`.
	pub fn held(&mut self, conversation: &ConversationId, count: usize, id: TurnId) {
		if let Some(lane) = self.0.get_mut(conversation) {
			let count = count.min(lane.waiting.len());
			lane.waiting.drain(..count);
			if lane.turns.back() != Some(&id) {
				lane.turns.push_back(id);
			}
		}
	}

	/// Put a turn a previous bot left open back in its lane. A delivering turn
	/// is already started, so its lane is busy.
	pub fn resume(&mut self, conversation: &ConversationId, id: TurnId, left: Left) {
		let lane = self.0.entry(conversation.clone()).or_default();
		match left {
			Left::Delivering => lane.busy = true,
			Left::Waiting => lane.turns.push_back(id),
		}
	}

	/// The oldest turn that has not started in an idle conversation. Turn
	/// numbers follow the order triggers were read.
	pub fn next(&self) -> Option<(ConversationId, TurnId)> {
		self.0
			.iter()
			.filter(|(_, lane)| !lane.busy)
			.filter_map(|(conversation, lane)| lane.turns.front().map(|id| (conversation, *id)))
			.min_by_key(|(_, id)| *id)
			.map(|(conversation, id)| (conversation.clone(), id))
	}

	/// The lane's oldest turn started. The lane is busy.
	pub fn started(&mut self, conversation: &ConversationId) {
		if let Some(lane) = self.0.get_mut(conversation) {
			lane.busy = true;
			lane.turns.pop_front();
		}
	}

	/// The lane's running turn was ended before it finished, so it is the
	/// next to start again and the lane is idle.
	pub fn halted(&mut self, conversation: &ConversationId, id: TurnId) {
		let lane = self.0.entry(conversation.clone()).or_default();
		lane.busy = false;
		lane.turns.push_front(id);
	}

	pub fn release(&mut self, conversation: &ConversationId) {
		if let Some(lane) = self.0.get_mut(conversation) {
			lane.busy = false;
		}
		self.0
			.retain(|_, lane| lane.busy || !lane.turns.is_empty() || !lane.waiting.is_empty());
	}

	/// Where a restart must read from to see the oldest trigger no turn holds,
	/// and the number that trigger has.
	pub fn oldest_waiting(&self) -> Option<(&Cursor, Seq)> {
		self.0
			.values()
			.filter_map(|lane| lane.waiting.front())
			.min_by_key(|queued| queued.trigger.seq)
			.map(|queued| (&queued.before, queued.trigger.seq))
	}

	/// Triggers no turn holds yet.
	pub fn waiting(&self) -> usize {
		self.0.values().map(|lane| lane.waiting.len()).sum()
	}

	/// The conversations with triggers no turn holds yet.
	pub fn waiting_conversations(&self) -> impl Iterator<Item = &ConversationId> {
		self.0
			.iter()
			.filter(|(_, lane)| !lane.waiting.is_empty())
			.map(|(conversation, _)| conversation)
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	fn queued(seq: u64) -> Queued {
		Queued {
			kind: Kind::Room,
			trigger: Trigger {
				seq: Seq(seq),
				event: Cursor::new(format!("e{seq}")).unwrap(),
				line: format!("l{seq}"),
				from: None,
				text: String::new(),
				files: Vec::new(),
			},
			before: Cursor::new(format!("e{}", seq - 1)).unwrap(),
		}
	}
	fn id(name: &str) -> ConversationId {
		ConversationId::new(name)
	}

	#[test]
	fn a_conversation_runs_one_turn_at_a_time_and_later_turns_wait_their_order() {
		let mut lanes = Lanes::default();
		lanes.queue(&id("a"), queued(1));
		lanes.held(&id("a"), 1, TurnId(0));
		assert_eq!(lanes.next(), Some((id("a"), TurnId(0))));
		lanes.started(&id("a"));
		lanes.queue(&id("a"), queued(2));
		lanes.held(&id("a"), 1, TurnId(1));
		assert!(lanes.next().is_none(), "a busy conversation starts no second turn");
		lanes.release(&id("a"));
		assert_eq!(lanes.next(), Some((id("a"), TurnId(1))));
	}

	#[test]
	fn nothing_leaves_the_queue_until_a_turn_holds_it() {
		let mut lanes = Lanes::default();
		lanes.queue(&id("a"), queued(1));
		assert!(lanes.oldest_unheld().is_some());
		assert_eq!(lanes.waiting(), 1, "peeking took the trigger");
		assert_eq!(
			lanes.oldest_waiting().map(|(cursor, seq)| (cursor.as_str(), seq.0)),
			Some(("e0", 1))
		);
		lanes.held(&id("a"), 1, TurnId(0));
		assert!(lanes.oldest_waiting().is_none(), "a held trigger still pins the cursor");
	}

	#[test]
	fn the_oldest_unheld_trigger_goes_first_and_names_the_turn_that_may_take_more() {
		let mut lanes = Lanes::default();
		lanes.queue(&id("late"), queued(99));
		for seq in 4..(4 + MAX_TRIGGERS as u64 + 2) {
			lanes.queue(&id("early"), queued(seq));
		}
		let unheld = lanes.oldest_unheld().unwrap();
		assert_eq!(unheld.conversation, id("early"));
		assert_eq!(unheld.triggers.len(), MAX_TRIGGERS);
		assert_eq!(unheld.newest, None);
		lanes.held(&id("early"), 3, TurnId(5));
		let unheld = lanes.oldest_unheld().unwrap();
		assert_eq!((unheld.triggers[0].seq, unheld.newest), (Seq(7), Some(TurnId(5))));
		lanes.held(&id("early"), MAX_TRIGGERS - 1, TurnId(5));
		assert_eq!(lanes.oldest_unheld().unwrap().conversation, id("late"));
	}

	#[test]
	fn a_resumed_delivery_holds_its_conversation_and_later_turns_wait_for_it() {
		let mut lanes = Lanes::default();
		lanes.resume(&id("a"), TurnId(3), Left::Delivering);
		lanes.resume(&id("a"), TurnId(4), Left::Waiting);
		lanes.resume(&id("b"), TurnId(5), Left::Waiting);
		assert_eq!(lanes.next(), Some((id("b"), TurnId(5))));
		lanes.started(&id("b"));
		assert!(lanes.next().is_none());
		lanes.release(&id("a"));
		assert_eq!(lanes.next(), Some((id("a"), TurnId(4))));
	}
}
