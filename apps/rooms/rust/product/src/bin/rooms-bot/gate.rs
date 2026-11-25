//! How much work one conversation may start. A conversation's addressed
//! messages start at most the conversation limit of them in an hour. A line
//! the limiter turns away gets no reply and no turn, and is kept as context
//! instead.
//!
//! The counts live in memory, so a restarted bot starts them over.
use super::rooms::ConversationId;
use std::{
	collections::{BTreeMap, VecDeque},
	time::Duration,
};
use tokio::time::Instant;

/// The window the hourly limit counts over.
const WINDOW: Duration = Duration::from_secs(3600);
/// The conversations the limiter keeps before it prunes the idle ones.
const PRUNE_ABOVE: usize = 4096;

pub struct Gate {
	/// The most turns one conversation may start in an hour.
	limit: u32,
	conversations: BTreeMap<ConversationId, VecDeque<Instant>>,
}

impl Gate {
	pub fn new(limit: u32) -> Self {
		Self {
			limit,
			conversations: BTreeMap::new(),
		}
	}

	/// Whether a line in `conversation` that addresses the bot starts work
	/// now. A line that starts work counts against the hourly limit, and a
	/// declined one does not.
	pub fn starts_work(&mut self, conversation: &ConversationId, now: Instant) -> bool {
		self.prune(now);
		let times = self.conversations.entry(conversation.clone()).or_default();
		while times
			.front()
			.is_some_and(|at| now.saturating_duration_since(*at) >= WINDOW)
		{
			times.pop_front();
		}
		if times.len() >= self.limit as usize {
			return false;
		}
		times.push_back(now);
		true
	}

	/// Past [`PRUNE_ABOVE`] entries, drop the ones whose last start left the
	/// window. A conversation still inside it keeps its count, so the map holds
	/// every conversation that started work in the last hour.
	fn prune(&mut self, now: Instant) {
		if self.conversations.len() > PRUNE_ABOVE {
			self.conversations.retain(|_, times| {
				times
					.back()
					.is_some_and(|at| now.saturating_duration_since(*at) < WINDOW)
			});
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	const LIMIT: u32 = 5;

	fn room(name: &str) -> ConversationId {
		ConversationId::new(name)
	}

	#[test]
	fn one_conversation_is_limited_within_the_hour_and_counts_again_after_it() {
		let mut gate = Gate::new(LIMIT);
		let start = Instant::now();
		for _ in 0..LIMIT {
			assert!(gate.starts_work(&room("r"), start));
		}
		assert!(!gate.starts_work(&room("r"), start));
		assert!(gate.starts_work(&room("s"), start));
		assert!(gate.starts_work(&room("r"), start + WINDOW));
	}

	#[test]
	fn a_declined_line_counts_against_nothing() {
		let mut gate = Gate::new(LIMIT);
		let start = Instant::now();
		for _ in 0..LIMIT {
			assert!(gate.starts_work(&room("r"), start));
		}
		let later = start + WINDOW - Duration::from_secs(1);
		for _ in 0..3 {
			assert!(!gate.starts_work(&room("r"), later));
		}
		let after = start + WINDOW;
		for _ in 0..LIMIT {
			assert!(gate.starts_work(&room("r"), after));
		}
		assert!(!gate.starts_work(&room("r"), after));
	}
}
