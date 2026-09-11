//! One bridged channel's membership on the shared feed, independent of any
//! one connection: joined while the room has readers or accepted outbound
//! work, and told apart from the channel's other traffic by the feed's own
//! nick. A reconnect installs a fresh generation; the join a stale
//! generation confirms is ignored.
use super::protocol::{encode, fold, nick_from_prefix, Message};
use alloc::{
	string::{String, ToString},
	vec::Vec,
};

/// What the feed must do for this channel after one call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
	/// A line for the feed's serialized writer.
	Send(Vec<u8>),
	/// Arm the join timer for this generation; `join_timed_out` fires it.
	ArmJoinTimer(u64),
	/// The channel failed on this connection; the bridge shows the reason.
	Fail(String),
}

/// The feed's own channel event, which must not appear as an IRC
/// participant in Rooms.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SelfEvent {
	None,
	/// The feed's own line, not the channel's.
	Own,
	Joined,
	Left,
}

#[derive(Debug)]
pub struct Relay {
	channel: String,
	self_nick: String,
	readers: usize,
	pending_posts: bool,
	connected: bool,
	joined: bool,
	joining: bool,
	generation: u64,
}

impl Relay {
	pub fn new(channel: &str, self_nick: &str) -> Self {
		Self {
			channel: channel.into(),
			self_nick: self_nick.into(),
			readers: 0,
			pending_posts: false,
			connected: false,
			joined: false,
			joining: false,
			generation: 0,
		}
	}
	pub fn channel(&self) -> &str {
		&self.channel
	}
	pub fn joined(&self) -> bool {
		self.joined
	}
	pub fn generation(&self) -> u64 {
		self.generation
	}
	pub fn is_self_nick(&self, nick: &str) -> bool {
		fold(nick) == fold(&self.self_nick)
	}
	pub fn is_channel(&self, value: &str) -> bool {
		fold(value) == fold(&self.channel)
	}
	/// Align IRC membership with the number of live Rooms readers.
	pub fn set_readers(&mut self, readers: usize) -> Vec<Action> {
		self.readers = readers;
		self.reconcile()
	}
	/// Accepted outbound work keeps the channel joined after its last reader
	/// leaves. The outbound owner clears this only after every receipt settles.
	pub fn set_pending_posts(&mut self, pending: bool) -> Vec<Action> {
		self.pending_posts = pending;
		self.reconcile()
	}
	/// A newly registered feed connection.
	pub fn connected(&mut self) -> Vec<Action> {
		self.generation += 1;
		self.connected = true;
		self.joined = false;
		self.joining = false;
		self.reconcile()
	}
	/// Only the connection retires; the readers stay counted for the next.
	pub fn disconnected(&mut self) {
		self.generation += 1;
		self.connected = false;
		self.joined = false;
		self.joining = false;
	}
	/// The join timer for `generation` fired.
	pub fn join_timed_out(&mut self, generation: u64) -> Vec<Action> {
		if self.generation != generation || !self.joining {
			return Vec::new();
		}
		self.retire(generation);
		alloc::vec![Action::Fail(alloc::format!(
			"IRC did not confirm joining {}",
			self.channel
		))]
	}
	/// A write for `generation` failed; the feed connection is over.
	pub fn send_failed(&mut self, generation: u64) {
		self.retire(generation);
	}
	/// The server refused the channel: this membership attempt ends without
	/// condemning the shared writer sibling channels use.
	pub fn refused(&mut self, reason: String) -> Vec<Action> {
		self.retire(self.generation);
		alloc::vec![Action::Fail(reason)]
	}
	/// Observe server-confirmed membership.
	pub fn observe(&mut self, message: &Message) -> (SelfEvent, Vec<Action>) {
		let nick = nick_from_prefix(message.prefix.as_deref());
		let own = nick.is_some_and(|nick| self.is_self_nick(nick));
		let ours = message.param(0).is_some_and(|value| self.is_channel(value));
		if own && message.is("JOIN") && ours {
			self.joining = false;
			self.joined = true;
			return (SelfEvent::Joined, self.reconcile());
		}
		let kicked = message.is("KICK") && ours && message.param(1).is_some_and(|nick| self.is_self_nick(nick));
		if kicked {
			let generation = self.generation;
			self.retire(generation);
			return (
				SelfEvent::Left,
				alloc::vec![Action::Fail(alloc::format!(
					"IRC bridge was kicked from {}",
					self.channel
				))],
			);
		}
		if own && message.is("PART") && ours {
			// A PART echo may race a freshly queued JOIN. It confirms the
			// older departure and must not cancel the newer join attempt.
			if self.joining {
				return (SelfEvent::Left, Vec::new());
			}
			self.joined = false;
			return (SelfEvent::Left, self.reconcile());
		}
		(if own { SelfEvent::Own } else { SelfEvent::None }, Vec::new())
	}
	fn wants_channel(&self) -> bool {
		self.readers > 0 || self.pending_posts
	}
	fn reconcile(&mut self) -> Vec<Action> {
		if !self.connected {
			return Vec::new();
		}
		if self.wants_channel() {
			if !self.joined && !self.joining {
				self.joining = true;
				return match encode("JOIN", &[&self.channel]) {
					Ok(line) => alloc::vec![Action::Send(line), Action::ArmJoinTimer(self.generation)],
					Err(error) => self.refused(error.to_string()),
				};
			}
			return Vec::new();
		}
		if self.joined {
			self.joined = false;
			return match encode("PART", &[&self.channel, "no Rooms readers"]) {
				Ok(line) => alloc::vec![Action::Send(line)],
				Err(_) => Vec::new(),
			};
		}
		Vec::new()
	}
	fn retire(&mut self, generation: u64) {
		if self.generation != generation {
			return;
		}
		self.generation += 1;
		self.connected = false;
		self.joined = false;
		self.joining = false;
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::server::irc::protocol::parse_line;

	fn line(text: &str) -> Message {
		parse_line(text).unwrap()
	}

	#[test]
	fn readers_join_and_part_the_channel_across_connections() {
		let mut relay = Relay::new("#news", "gwbot");
		assert!(relay.set_readers(1).is_empty(), "nothing to send before a connection");
		let actions = relay.connected();
		assert_eq!(actions[0], Action::Send(b"JOIN #news\r\n".to_vec()));
		assert_eq!(actions[1], Action::ArmJoinTimer(1));
		let (event, _) = relay.observe(&line(":gwbot!u@h JOIN :#news"));
		assert_eq!(event, SelfEvent::Joined);
		assert!(relay.joined());
		assert!(relay.join_timed_out(1).is_empty(), "a confirmed join ignores its timer");
		let (event, _) = relay.observe(&line(":alice!u@h PRIVMSG #news :hi"));
		assert_eq!(event, SelfEvent::None);
		let (event, _) = relay.observe(&line(":gwbot!u@h PRIVMSG #news :hi"));
		assert_eq!(event, SelfEvent::Own);
		let actions = relay.set_readers(0);
		assert_eq!(actions, [Action::Send(b"PART #news :no Rooms readers\r\n".to_vec())]);
		relay.disconnected();
		relay.set_readers(2);
		let actions = relay.connected();
		assert!(matches!(actions[0], Action::Send(_)));
	}

	#[test]
	fn accepted_posts_hold_membership_and_late_join_without_demand_parts() {
		let mut relay = Relay::new("#news", "gwbot");
		relay.set_readers(1);
		relay.connected();
		relay.set_pending_posts(true);
		assert!(relay.set_readers(0).is_empty());
		assert!(relay.observe(&line(":gwbot!u@h JOIN :#news")).1.is_empty());
		assert!(relay.joined());
		assert!(matches!(relay.set_pending_posts(false).as_slice(), [Action::Send(_)]));
		relay.disconnected();
		relay.set_readers(1);
		relay.connected();
		relay.set_readers(0);
		let (_, actions) = relay.observe(&line(":gwbot!u@h JOIN :#news"));
		assert_eq!(actions, [Action::Send(b"PART #news :no Rooms readers\r\n".to_vec())]);
		assert!(!relay.joined());
	}

	#[test]
	fn a_kick_or_a_silent_join_fails_the_channel() {
		let mut relay = Relay::new("#news", "gwbot");
		relay.set_readers(1);
		let actions = relay.connected();
		let Action::ArmJoinTimer(generation) = actions[1] else {
			panic!("no timer armed");
		};
		let failed = relay.join_timed_out(generation);
		assert!(matches!(&failed[0], Action::Fail(reason) if reason.contains("did not confirm")));
		let mut kicked = Relay::new("#news", "gwbot");
		kicked.set_readers(1);
		kicked.connected();
		kicked.observe(&line(":gwbot!u@h JOIN :#news"));
		let (event, actions) = kicked.observe(&line(":op!u@h KICK #news gwbot :bye"));
		assert_eq!(event, SelfEvent::Left);
		assert!(matches!(&actions[0], Action::Fail(reason) if reason.contains("kicked")));
	}
}
