//! Who may start work, and how much. The operator names the people the bot
//! answers, and three limits bound the work anyone can start: messages in an
//! hour from one person, messages in an hour in one conversation, and replies
//! in a row to one person in one conversation, which stops bots from
//! answering each other without end however many take part. Only that
//! person going quiet starts their count over, so nobody else's lines can
//! reset it. A line the gate turns away gets no reply and no turn, and is
//! kept as context instead.
//!
//! The counts live in memory, so a restarted bot starts them over.
use super::rooms::ConversationId;
use rooms_application::room::inbox::{nick_key as key, same_nick};
use std::{
	collections::{BTreeMap, VecDeque},
	time::Duration,
};
use tokio::time::Instant;

/// The window the two hourly limits count over.
const WINDOW: Duration = Duration::from_secs(60 * 60);
/// How long one person must be quiet in a conversation before replies to
/// them count from zero again.
pub const QUIET: Duration = Duration::from_secs(10 * 60);
/// The most people and conversations the gate keeps counts for. Past it,
/// counts that no longer limit anything are dropped first.
const MAX_TRACKED: usize = 4096;

/// The operator's settings the gate applies.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Policy<'a> {
	/// Nicknames the bot answers. Empty means everyone.
	pub allow: &'a [String],
	pub sender_limit: u32,
	pub conversation_limit: u32,
	pub streak_limit: u32,
}

impl Policy<'_> {
	/// Whether a line from `sender` may reach the agent at all. With an allow
	/// list, only the names on it may, as Rooms compares nicknames, and a
	/// sender the session did not name may not. Without one, everyone may.
	pub fn admits(&self, sender: Option<&str>) -> bool {
		self.allow.is_empty() || sender.is_some_and(|name| self.allow.iter().any(|allowed| same_nick(allowed, name)))
	}
}

/// Why a line was turned away.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Declined {
	NotAllowed,
	SenderLimit,
	ConversationLimit,
	Streak,
}

impl Declined {
	/// Words for the log.
	pub fn reason(self) -> &'static str {
		match self {
			Self::NotAllowed => "the sender is not on the allow list",
			Self::SenderLimit => "the sender reached the hourly limit",
			Self::ConversationLimit => "the conversation reached the hourly limit",
			Self::Streak => "the bot answered this sender too many times in a row",
		}
	}
}

/// Replies in a row to one sender in one conversation.
struct Streak {
	count: u32,
	last: Instant,
}

#[derive(Default)]
pub struct Gate {
	senders: BTreeMap<String, VecDeque<Instant>>,
	conversations: BTreeMap<ConversationId, VecDeque<Instant>>,
	streaks: BTreeMap<(ConversationId, Option<String>), Streak>,
}

/// Drop the times older than the window, and say whether `limit` more fit.
fn room_in(times: &mut VecDeque<Instant>, now: Instant, limit: u32) -> bool {
	while times
		.front()
		.is_some_and(|at| now.saturating_duration_since(*at) >= WINDOW)
	{
		times.pop_front();
	}
	times.len() < limit as usize
}

impl Gate {
	/// Whether a line from `sender` in `conversation` that addresses the bot
	/// starts work now. `sender` is the nickname Rooms gives the sender, and
	/// `None` when the session named nobody. An answered line counts against
	/// every limit, and a declined one against none.
	pub fn trigger(
		&mut self,
		policy: &Policy<'_>,
		conversation: &ConversationId,
		sender: Option<&str>,
		now: Instant,
	) -> Result<(), Declined> {
		if !policy.admits(sender) {
			return Err(Declined::NotAllowed);
		}
		let sender = sender.map(key);
		self.prune(now);
		let streak = (conversation.clone(), sender.clone());
		let count = match self.streaks.get(&streak) {
			Some(held) if now.saturating_duration_since(held.last) < QUIET => held.count.saturating_add(1),
			_ => 1,
		};
		self.streaks.insert(streak, Streak { count, last: now });
		if count > policy.streak_limit {
			return Err(Declined::Streak);
		}
		let by_sender = sender
			.as_ref()
			.map(|name| self.senders.entry(name.clone()).or_default());
		if let Some(times) = by_sender
			&& !room_in(times, now, policy.sender_limit)
		{
			return Err(Declined::SenderLimit);
		}
		let by_conversation = self.conversations.entry(conversation.clone()).or_default();
		if !room_in(by_conversation, now, policy.conversation_limit) {
			return Err(Declined::ConversationLimit);
		}
		by_conversation.push_back(now);
		if let Some(name) = sender {
			self.senders.entry(name).or_default().push_back(now);
		}
		Ok(())
	}

	/// Keep the maps bounded: past [`MAX_TRACKED`] entries, drop the ones that
	/// no longer limit anything.
	fn prune(&mut self, now: Instant) {
		let live = |times: &mut VecDeque<Instant>| {
			room_in(times, now, 0);
			!times.is_empty()
		};
		if self.senders.len() > MAX_TRACKED {
			self.senders.retain(|_, times| live(times));
		}
		if self.conversations.len() > MAX_TRACKED {
			self.conversations.retain(|_, times| live(times));
		}
		if self.streaks.len() > MAX_TRACKED {
			self.streaks
				.retain(|_, streak| now.saturating_duration_since(streak.last) < QUIET);
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	fn policy(allow: &[String]) -> Policy<'_> {
		Policy {
			allow,
			sender_limit: 3,
			conversation_limit: 5,
			streak_limit: 4,
		}
	}
	fn room(name: &str) -> ConversationId {
		ConversationId::new(name)
	}

	#[test]
	fn an_allow_list_answers_only_the_names_on_it_without_regard_to_case() {
		let allow = vec!["Ann".to_owned()];
		let mut gate = Gate::default();
		let now = Instant::now();
		assert_eq!(gate.trigger(&policy(&allow), &room("r"), Some("ann"), now), Ok(()));
		assert_eq!(
			gate.trigger(&policy(&allow), &room("r"), Some("bob"), now),
			Err(Declined::NotAllowed)
		);
		assert_eq!(
			gate.trigger(&policy(&allow), &room("d"), None, now),
			Err(Declined::NotAllowed),
			"a sender the session did not name is not on any list"
		);
		assert_eq!(
			gate.trigger(&policy(&[]), &room("d"), None, now),
			Ok(()),
			"no list answers everyone"
		);
	}

	#[test]
	fn names_compare_the_way_rooms_compares_them_beyond_ascii() {
		let allow = vec!["Émile".to_owned()];
		let mut gate = Gate::default();
		let now = Instant::now();
		assert_eq!(gate.trigger(&policy(&allow), &room("r"), Some("émile"), now), Ok(()));
		assert_eq!(
			gate.trigger(&policy(&allow), &room("r"), Some("emile"), now),
			Err(Declined::NotAllowed)
		);
	}

	#[test]
	fn one_sender_is_limited_across_conversations_within_the_hour() {
		let mut gate = Gate::default();
		let start = Instant::now();
		for (at, conversation) in ["a", "b", "c"].into_iter().enumerate() {
			let now = start + Duration::from_secs(at as u64);
			assert_eq!(
				gate.trigger(&policy(&[]), &room(conversation), Some("ann"), now),
				Ok(())
			);
		}
		let later = start + Duration::from_secs(10);
		assert_eq!(
			gate.trigger(&policy(&[]), &room("d"), Some("Ann"), later),
			Err(Declined::SenderLimit)
		);
		assert_eq!(gate.trigger(&policy(&[]), &room("d"), Some("bob"), later), Ok(()));
		let after_the_hour = start + WINDOW;
		assert_eq!(
			gate.trigger(&policy(&[]), &room("e"), Some("ann"), after_the_hour),
			Ok(())
		);
	}

	#[test]
	fn one_conversation_is_limited_whoever_writes() {
		let mut gate = Gate::default();
		let now = Instant::now();
		for name in ["a", "b", "c", "d", "e"] {
			assert_eq!(gate.trigger(&policy(&[]), &room("r"), Some(name), now), Ok(()));
		}
		assert_eq!(
			gate.trigger(&policy(&[]), &room("r"), Some("f"), now),
			Err(Declined::ConversationLimit)
		);
		assert_eq!(gate.trigger(&policy(&[]), &room("s"), Some("f"), now), Ok(()));
	}

	#[test]
	fn replies_in_a_row_to_one_sender_stop_until_they_go_quiet_whoever_else_speaks() {
		let loose = Policy {
			sender_limit: 100,
			conversation_limit: 100,
			..policy(&[])
		};
		let mut gate = Gate::default();
		let start = Instant::now();
		let mut at = start;
		for _ in 0..4 {
			at += Duration::from_secs(30);
			assert_eq!(gate.trigger(&loose, &room("r"), Some("bot2"), at), Ok(()));
		}
		at += Duration::from_secs(30);
		assert_eq!(
			gate.trigger(&loose, &room("r"), Some("bot2"), at),
			Err(Declined::Streak)
		);
		// The same sender writing on without a pause stays turned away.
		at += Duration::from_secs(30);
		assert_eq!(
			gate.trigger(&loose, &room("r"), Some("bot2"), at),
			Err(Declined::Streak)
		);
		// A third and fourth speaker taking turns with it reset nothing, and
		// each runs a count of its own.
		for _ in 0..4 {
			for other in ["bot3", "ann"] {
				at += Duration::from_secs(10);
				assert_eq!(gate.trigger(&loose, &room("r"), Some(other), at), Ok(()));
			}
			at += Duration::from_secs(10);
			assert_eq!(
				gate.trigger(&loose, &room("r"), Some("BOT2"), at),
				Err(Declined::Streak)
			);
		}
		at += Duration::from_secs(10);
		assert_eq!(
			gate.trigger(&loose, &room("r"), Some("bot3"), at),
			Err(Declined::Streak),
			"three bots taking turns ran past the limit"
		);
		at += QUIET;
		assert_eq!(
			gate.trigger(&loose, &room("r"), Some("bot2"), at),
			Ok(()),
			"a quiet gap starts over"
		);
		// The same name in another conversation is a count of its own.
		at += Duration::from_secs(1);
		assert_eq!(gate.trigger(&loose, &room("s"), Some("bot3"), at), Ok(()));
	}
}
