//! An IRC channel presented as an ordinary Rooms room. The IRC edge carries
//! no capability semantics: this translates the channel's roster and
//! messages into the same public Rooms verbs every other room answers, and
//! says what each member hears. The connection that carries a member is
//! the adapter's. Here a member is a connection id and an inbox.
mod invalid;
mod outcome;
use super::{
	VIEWER_LIMIT,
	protocol::{Message, bare_names_nick, ctcp_action_text, fold, nick_from_prefix},
	relay::{Relay, SelfEvent},
	roster::{Roster, display_nick},
	seat::{self, View},
	wire::Notice,
};
use crate::{
	directory::{MAX_ORIGIN, MAX_PUBLICATION_ID, OriginProof, PublicationKind, RoomInfo},
	failure::FailureCode,
	fields::{Nullable, Text},
	room::{
		inbox::{MAX_NICK, nick_refusal},
		message::LineId,
		policy::MembershipKind,
		subject::Subject,
	},
	server::rooms::MAX_ROOM,
};
use alloc::{
	collections::BTreeMap,
	format,
	string::{String, ToString},
	vec::Vec,
};
pub use invalid::Invalid;
pub use outcome::{Effects, Refusal};

/// The longest away reason, the Rooms room's bound.
pub use crate::room::membership::MAX_AWAY;

#[derive(Debug)]
struct Member<R> {
	nick: String,
	inbox: R,
	away: String,
	kind: MembershipKind,
}

/// A post admitted but not yet delivered to IRC: the gateway delivers it status-allow: pending state or quoted runtime label
/// as the member, then commits the same authorship to Rooms.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Post {
	pub from: String,
	pub text: String,
	line: LineId,
}

/// Whether a nick is reserved for members bridged from elsewhere.
pub fn prefix_refusal(nick: &str) -> Option<String> {
	nick.to_lowercase().starts_with(seat::PREFIX).then(|| {
		format!(
			"names beginning with \"{}\" are reserved for members bridged from elsewhere",
			seat::PREFIX
		)
	})
}

#[derive(Debug)]
pub struct Room<C, R> {
	network: String,
	channel: String,
	name: String,
	publication_id: String,
	origin: String,
	members: BTreeMap<C, Member<R>>,
	irc: Roster,
	names_pending: Option<BTreeMap<String, String>>,
	/// The channel's topic exactly as the channel last said it, so a topic
	/// said again, as every rejoin does, is no news.
	topic: String,
	/// That topic as this room's subject, told to every arrival. It is the
	/// last one the channel said, kept while the feed is away, and the next
	/// join corrects it.
	subject: Subject,
	/// Whether the channel has said its topic since the feed last joined. A
	/// server says a topic before the end of its names reply and says nothing
	/// for a channel without one, so a join that ends its names unheard has no
	/// topic.
	topic_heard: bool,
	relay: Relay,
	next_line: u64,
}

fn valid_network(network: &str) -> bool {
	let mut chars = network.chars();
	chars.next().is_some_and(|c| c.is_ascii_alphanumeric())
		&& chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-'))
}

fn valid_channel(channel: &str) -> bool {
	channel.starts_with('#')
		&& !channel
			.chars()
			.any(|c| matches!(c, '\0' | '\u{7}' | '\n' | '\r' | ' ' | ',' | ':'))
}

impl<C: Copy + Ord, R: Clone> Room<C, R> {
	pub fn new(
		network: &str,
		channel: &str,
		feed_nick: &str,
		publication_id: &str,
		origin: &str,
	) -> Result<Self, Invalid> {
		if !valid_network(network) {
			return Err(Invalid::NetworkName);
		}
		if !valid_channel(channel) {
			return Err(Invalid::Channel);
		}
		if publication_id.is_empty() || publication_id.len() > MAX_PUBLICATION_ID {
			return Err(Invalid::PublicationIdentity);
		}
		if origin.is_empty() || origin.len() > MAX_ORIGIN {
			return Err(Invalid::Origin);
		}
		let name = format!("{network}/{channel}");
		if name.encode_utf16().count() > MAX_ROOM {
			return Err(Invalid::RoomNameLength);
		}
		Ok(Self {
			network: network.into(),
			channel: channel.into(),
			name,
			publication_id: publication_id.into(),
			origin: origin.into(),
			members: BTreeMap::new(),
			irc: Roster::default(),
			names_pending: None,
			topic: String::new(),
			subject: Subject::default(),
			topic_heard: true,
			relay: Relay::new(channel, feed_nick),
			next_line: 1,
		})
	}
	pub fn network(&self) -> &str {
		&self.network
	}
	pub fn channel(&self) -> &str {
		&self.channel
	}
	pub fn name(&self) -> &str {
		&self.name
	}
	pub fn publication_id(&self) -> &str {
		&self.publication_id
	}
	pub fn origin(&self) -> &str {
		&self.origin
	}
	pub fn relay(&mut self) -> &mut Relay {
		&mut self.relay
	}
	pub fn members(&self) -> impl Iterator<Item = (C, &str)> {
		self.members.iter().map(|(c, m)| (*c, m.nick.as_str()))
	}
	pub fn is_member(&self, connection: C) -> bool {
		self.members.contains_key(&connection)
	}
	pub fn member_nick(&self, connection: C) -> Option<&str> {
		self.members.get(&connection).map(|m| m.nick.as_str())
	}
	/// The connection carrying the member called `nick`.
	pub fn member_by_nick(&self, nick: &str) -> Option<C> {
		let folded = fold(nick);
		self.members
			.iter()
			.find(|(_, member)| fold(&member.nick) == folded)
			.map(|(c, _)| *c)
	}
	fn count(&self) -> usize {
		self.irc.len() + self.members.len()
	}
	/// The public entry a directory lists this room as.
	pub fn info(&self) -> RoomInfo {
		RoomInfo {
			id: Text(self.publication_id.as_str().into()),
			name: Text(self.name.as_str().into()),
			kind: PublicationKind::Bridge,
			count: Nullable::Value(crate::server::rooms::roster_count(self.count())),
			origin: Text(self.origin.as_str().into()),
			proof: OriginProof::Bridge,
			offers: Nullable::Value(MembershipKind::Participant),
		}
	}
	fn visible_nicks(&self) -> Vec<String> {
		let mut names = self.irc.sorted_names();
		names.extend(self.members.values().map(|m| m.nick.clone()));
		names.sort();
		names
	}
	fn tell_all(&self, effects: &mut Effects<C, R>, notice: Notice) {
		for (connection, member) in &self.members {
			effects.tells.push((*connection, member.inbox.clone(), notice.clone()));
		}
	}
	/// Hold the channel's subject and tell every member when it changes.
	fn set_subject(&mut self, effects: &mut Effects<C, R>, subject: Subject) {
		if self.subject != subject {
			self.subject = subject.clone();
			self.tell_all(effects, Notice::Subject { subject, changed: true });
		}
	}
	fn tell_one(&self, effects: &mut Effects<C, R>, connection: C, notice: Notice) {
		if let Some(member) = self.members.get(&connection) {
			effects.tells.push((connection, member.inbox.clone(), notice));
		}
	}
	/// A roster is a full replacement on every client, so the seat views
	/// follow it at once: clearing IRC names must not erase the link state
	/// of the Rooms members.
	fn broadcast_roster(&self, effects: &mut Effects<C, R>, said: &str, seat_view: &dyn Fn(C) -> Option<View>) {
		self.tell_all(
			effects,
			Notice::Roster {
				said: said.into(),
				names: self.visible_nicks(),
			},
		);
		for (seated, member) in &self.members {
			if let Some(view) = seat_view(*seated) {
				self.tell_all(
					effects,
					Notice::Seat {
						nick: member.nick.clone(),
						view,
					},
				);
			}
		}
	}
	/// Check admission before an adapter replaces an existing membership.
	pub fn admit_reader(&self, connection: C, nick: &str) -> Result<(), Refusal> {
		if let Some(refused) = nick_refusal(nick) {
			return Err(Refusal::plain(refused));
		}
		if let Some(reserved) = prefix_refusal(nick) {
			return Err(Refusal::plain(reserved));
		}
		if !self.members.contains_key(&connection) && self.members.len() >= VIEWER_LIMIT {
			return Err(Refusal::plain(format!(
				"this IRC bridge already has {VIEWER_LIMIT} Rooms readers"
			)));
		}
		let folded = fold(nick);
		if self
			.members
			.iter()
			.any(|(held, member)| *held != connection && fold(&member.nick) == folded)
		{
			return Err(Refusal::plain(format!("the name \"{nick}\" is already here")));
		}
		Ok(())
	}
	pub fn membership_kind(&self, connection: C) -> Result<MembershipKind, Refusal> {
		self.members
			.get(&connection)
			.map(|m| m.kind)
			.ok_or_else(|| Refusal::coded(FailureCode::NotRoomMember, "this IRC bridge membership has ended"))
	}
	/// Admit one post without changing either side.
	pub fn prepare_post(&mut self, connection: C, text: &str) -> Result<Post, Refusal> {
		let member = self
			.members
			.get(&connection)
			.ok_or_else(|| Refusal::coded(FailureCode::NotRoomMember, "this IRC bridge membership has ended"))?;
		if member.kind != MembershipKind::Participant {
			return Err(Refusal::coded(
				FailureCode::ReadOnlyMembership,
				"this observer membership cannot speak to IRC",
			));
		}
		let from = member.nick.clone();
		let line = self.reserve_line()?;
		Ok(Post {
			from,
			text: text.into(),
			line,
		})
	}
	fn reserve_line(&mut self) -> Result<LineId, Refusal> {
		let line =
			LineId::new(self.next_line).ok_or_else(|| Refusal::plain("IRC bridge line identifiers exhausted"))?;
		self.next_line += 1;
		Ok(line)
	}
	/// Echo a post already accepted by its IRC delivery.
	pub fn commit_post(&self, post: &Post) -> Effects<C, R> {
		let mut effects = Effects::default();
		self.tell_all(
			&mut effects,
			Notice::Line {
				from: post.from.clone(),
				text: post.text.clone(),
				line: post.line,
			},
		);
		effects
	}
	pub fn away(&mut self, connection: C, why: &str) -> Result<Effects<C, R>, Refusal> {
		if why.encode_utf16().count() > MAX_AWAY {
			return Err(Refusal::plain(format!(
				"an away reason may be at most {MAX_AWAY} characters"
			)));
		}
		let member = self
			.members
			.get_mut(&connection)
			.ok_or_else(|| Refusal::coded(FailureCode::NotRoomMember, "this IRC bridge membership has ended"))?;
		let mut effects = Effects::default();
		if member.away == why {
			return Ok(effects);
		}
		member.away = why.into();
		let nick = member.nick.clone();
		self.tell_all(&mut effects, Notice::Away { nick, why: why.into() });
		Ok(effects)
	}
	/// A member leaves on their own word.
	pub fn leave(&mut self, connection: C) -> Effects<C, R> {
		self.drop_member(connection, true)
	}
	/// The gateway ends a membership, saying why when it has a reason.
	pub fn retire(&mut self, connection: C, ended: Option<&str>) -> Effects<C, R> {
		let mut effects = Effects::default();
		if let Some(ended) = ended {
			self.tell_one(&mut effects, connection, Notice::Ended(ended.into()));
		}
		effects.extend(self.drop_member(connection, true));
		effects
	}
	fn drop_member(&mut self, connection: C, announce: bool) -> Effects<C, R> {
		let mut effects = Effects::default();
		let Some(member) = self.members.remove(&connection) else {
			return effects;
		};
		effects.releases.push((connection, member.inbox));
		effects.presence.push(connection);
		effects.relay.extend(self.relay.set_readers(self.members.len()));
		if announce {
			self.tell_all(
				&mut effects,
				Notice::Leave {
					said: format!("{} left ({} here)", member.nick, self.count()),
					nick: member.nick,
				},
			);
		}
		effects.count_changed = true;
		effects
	}
	/// Say one room line to one member: seat news that concerns only them.
	pub fn note_to(&self, connection: C, text: &str) -> Effects<C, R> {
		let mut effects = Effects::default();
		self.tell_one(&mut effects, connection, Notice::room(text));
		effects
	}
	/// One member's projection changed: every member hears the row anew.
	pub fn seat_changed(&self, connection: C, view: View) -> Effects<C, R> {
		let mut effects = Effects::default();
		if let Some(member) = self.members.get(&connection) {
			self.tell_all(
				&mut effects,
				Notice::Seat {
					nick: member.nick.clone(),
					view,
				},
			);
		}
		effects
	}
	pub fn authority_changed(&self, kind: &'static str, token: &str) -> Effects<C, R> {
		let mut effects = Effects::default();
		self.tell_all(
			&mut effects,
			Notice::AuthorityChanged {
				kind,
				token: token.into(),
			},
		);
		effects
	}
	/// The feed connection ended: its roster was connection-scoped.
	pub fn disconnected(&mut self, seat_view: &dyn Fn(C) -> Option<View>) -> Effects<C, R> {
		self.relay.disconnected();
		self.clear_roster("the IRC connection ended", seat_view)
	}
	/// The feed stays registered but parted this channel.
	pub fn left_channel(&mut self, seat_view: &dyn Fn(C) -> Option<View>) -> Effects<C, R> {
		self.clear_roster("the bridge left the IRC channel", seat_view)
	}
	fn clear_roster(&mut self, notice: &str, seat_view: &dyn Fn(C) -> Option<View>) -> Effects<C, R> {
		self.names_pending = None;
		let mut effects = Effects::default();
		if !self.irc.clear() {
			return effects;
		}
		self.broadcast_roster(&mut effects, notice, seat_view);
		effects.count_changed = true;
		effects
	}
	/// One message from the feed, once registered. `seat_nick` says whether
	/// an IRC nick is one of this room's own members speaking through their
	/// own connection: their presence and lines are the member the room
	/// already shows, so echoing them back would double every seated member.
	pub fn observe(
		&mut self,
		message: &Message,
		seat_nick: &dyn Fn(&str) -> bool,
		seat_view: &dyn Fn(C) -> Option<View>,
	) -> Result<Effects<C, R>, Refusal> {
		let (own, actions) = self.relay.observe(message);
		let mut effects = Effects {
			relay: actions,
			..Effects::default()
		};
		match own {
			SelfEvent::Left => {
				effects.extend(self.left_channel(seat_view));
				return Ok(effects);
			}
			SelfEvent::Joined => {
				self.topic_heard = false;
				return Ok(effects);
			}
			SelfEvent::Own => return Ok(effects),
			SelfEvent::None => {}
		}
		effects.extend(self.apply(message, seat_nick, seat_view)?);
		Ok(effects)
	}
	fn apply(
		&mut self,
		message: &Message,
		seat_nick: &dyn Fn(&str) -> bool,
		seat_view: &dyn Fn(C) -> Option<View>,
	) -> Result<Effects<C, R>, Refusal> {
		let mut effects = Effects::default();
		let ours = |value: Option<&str>| value.is_some_and(|v| fold(v) == fold(&self.channel));
		if message.is("353") {
			let n = message.params.len();
			let (Some(channel), Some(names)) = (n.checked_sub(2).and_then(|at| message.param(at)), message.last())
			else {
				return Ok(effects);
			};
			if !ours(Some(channel)) {
				return Ok(effects);
			}
			let pending = self.names_pending.get_or_insert_with(BTreeMap::new);
			for field in names.split_whitespace() {
				let nick = bare_names_nick(field);
				if !nick.is_empty() && !self.relay.is_self_nick(nick) && !seat_nick(nick) {
					Roster::assemble(pending, nick)?;
				}
			}
			return Ok(effects);
		}
		if message.is("366") {
			let n = message.params.len();
			let channel = n.checked_sub(2).and_then(|at| message.param(at));
			if ours(channel)
				&& let Some(pending) = self.names_pending.take()
			{
				self.irc.replace(pending);
				self.broadcast_roster(&mut effects, "the IRC roster was refreshed", seat_view);
				effects.count_changed = true;
			}
			if ours(channel) && !self.topic_heard {
				self.topic_heard = true;
				self.topic.clear();
				self.set_subject(&mut effects, Subject::default());
			}
			return Ok(effects);
		}
		let Some(nick) = nick_from_prefix(message.prefix.as_deref()) else {
			return Ok(effects);
		};
		if self.relay.is_self_nick(nick) || seat_nick(nick) {
			return Ok(effects);
		}
		let nick = nick.to_string();
		if message.is("PRIVMSG") && message.params.len() >= 2 && ours(message.param(0)) {
			// A CTCP ACTION crosses as the rooms wire form for one, so every
			// rooms client draws the action it already knows how to draw.
			let raw = message.param(1).unwrap_or("");
			let text = match ctcp_action_text(raw) {
				Some(action) => format!("/me {action}"),
				None => raw.into(),
			};
			let line = self.reserve_line()?;
			self.tell_all(
				&mut effects,
				Notice::Line {
					from: display_nick(&nick)?,
					text,
					line,
				},
			);
			return Ok(effects);
		}
		let topic_numeric =
			message.is("332") && ours(message.params.len().checked_sub(2).and_then(|at| message.param(at)));
		if (message.is("TOPIC") && ours(message.param(0))) || topic_numeric {
			// A topic this room cannot hold as a subject is said as a plain
			// line, and the subject before it is taken down rather than left
			// standing as the channel's.
			self.topic_heard = true;
			let topic = message.last().unwrap_or("");
			if topic == self.topic {
				return Ok(effects);
			}
			self.topic = topic.into();
			let subject = Subject::new(String::from(topic), None).unwrap_or_else(|why| {
				self.tell_all(
					&mut effects,
					Notice::room(format!(
						"the channel's topic cannot be this room's subject ({why}): {topic}"
					)),
				);
				Subject::default()
			});
			self.set_subject(&mut effects, subject);
			return Ok(effects);
		}
		if message.is("JOIN") && ours(message.param(0)) {
			if let Some(display) = self.irc.add(&nick)? {
				self.tell_all(
					&mut effects,
					Notice::Join {
						said: format!("{display} joined IRC"),
						nick: display,
					},
				);
				effects.count_changed = true;
			}
			return Ok(effects);
		}
		if message.is("PART") && ours(message.param(0)) {
			self.remove_irc(&mut effects, &nick);
			return Ok(effects);
		}
		if message.is("KICK") && ours(message.param(0)) {
			if let Some(kicked) = message.param(1) {
				let kicked = kicked.to_string();
				self.remove_irc(&mut effects, &kicked);
			}
			return Ok(effects);
		}
		if message.is("QUIT") {
			self.remove_irc(&mut effects, &nick);
			return Ok(effects);
		}
		if message.is("NICK")
			&& let Some(next) = message.param(0)
			&& let Some((was, now)) = self.irc.rename(&nick, next)?
		{
			self.tell_all(
				&mut effects,
				Notice::Leave {
					said: format!("{was} is now {now}"),
					nick: was,
				},
			);
			self.tell_all(
				&mut effects,
				Notice::Join {
					said: format!("{now} joined"),
					nick: now,
				},
			);
			effects.count_changed = true;
		}
		Ok(effects)
	}
	fn remove_irc(&mut self, effects: &mut Effects<C, R>, nick: &str) {
		if let Some(present) = self.irc.remove(nick) {
			self.tell_all(
				effects,
				Notice::Leave {
					said: format!("{present} left IRC"),
					nick: present,
				},
			);
			effects.count_changed = true;
		}
	}
	/// The longest line a member may post here, in bytes: IRC's line less
	/// the channel and the widest attribution.
	pub fn line_bytes(&self) -> u64 {
		let fixed = format!("PRIVMSG {} :<> \r\n", self.channel).len();
		(super::protocol::LINE_BYTES.saturating_sub(fixed + MAX_NICK * 3)) as u64
	}
}

#[cfg(test)]
mod tests;

mod subscription;
