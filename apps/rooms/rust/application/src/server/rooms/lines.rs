//! What holding a line's reference lets somebody do to it, and the same one
//! level up for the room's topic. Neither asks who is calling: possession
//! already answered the question, which is what makes the authority passable.
use super::{entrance::LossyString, notice::Notice, Effects, LineKey, Refusal, RoomKey, Rooms, MAX_TOPIC};
use crate::{
	files::FileLineError,
	room::{message::ChangeKind, ArgumentView},
	server::{history::Persist, links::Authority},
};
use alloc::{format, string::String, vec::Vec};

impl<C: Copy + Ord, R: Clone> Rooms<C, R> {
	/// Dispatch a line verb. The staged files a refile adds are the calling
	/// connection's own in the line's room, even when the line was handed to
	/// that connection by somebody else.
	pub fn line_verb<A: ArgumentView>(
		&mut self,
		connection: C,
		key: LineKey,
		verb: &str,
		args: &[A],
		monotonic_ms: u64,
	) -> Result<super::Mutation<C, R>, Refusal> {
		self.file_time(monotonic_ms)?;
		let Some(line) = self.lines.get_mut(&key) else {
			return Err(Refusal::plain("that line was withdrawn"));
		};
		let member = self
			.rooms
			.get(&line.room)
			.and_then(|room| room.member_of(connection))
			.map(|member| &member.files);
		let change = self
			.files
			.dispatch_line(member, &mut line.line, verb, args)
			.map_err(|error| match error {
				FileLineError::Line(error) => Refusal::plain(error.to_string_lossy()),
				FileLineError::Files(error) => Refusal::plain(error.to_string_lossy()),
			})?;
		let Some(change) = change else {
			return Ok(super::Mutation::default());
		};
		let (room, from, id, kind, text) = (
			line.room.clone(),
			String::from(change.from),
			change.id,
			change.kind,
			String::from(change.text),
		);
		let blobs: Vec<_> = change.files.iter().map(|file| file.blob()).collect();
		let kept = line.kept;
		let mut effects = Effects::default();
		let mut mutation = super::Mutation::default();
		if let (Some(history), Some(token)) = (self.history.as_mut(), kept) {
			let persist: Option<Persist> = match kind {
				ChangeKind::Withdrawn => history.forget(&room, token),
				ChangeKind::Edited | ChangeKind::Refiled => history
					.update(&room, token, &text)
					.map_err(|error| Refusal::plain(error.to_string_lossy()))?,
				ChangeKind::Said => None,
			};
			mutation.persist = persist;
		}
		self.broadcast(
			&room,
			&mut effects,
			Notice::Line {
				from,
				text,
				marker: Some((kind, id)),
				files: blobs,
			},
			None,
		);
		mutation.effects = effects;
		Ok(mutation)
	}

	/// Whether a line still answers: a withdrawn line refuses an edit rather
	/// than putting text back its author took down.
	pub fn line_withdrawn(&self, key: LineKey) -> bool {
		self.lines.get(&key).is_none_or(|line| line.line.is_withdrawn())
	}

	/// The authority successor a topic change persists first, when the room
	/// has a durable name; `Ok(None)` when the topic already stands so.
	pub fn prepare_topic(
		&self,
		room: &RoomKey,
		text: &str,
		authority: &Authority,
	) -> Result<Option<Option<Authority>>, Refusal> {
		if text.encode_utf16().count() > MAX_TOPIC {
			return Err(Refusal::plain(format!("a topic may be at most {MAX_TOPIC} characters")));
		}
		let held = self
			.rooms
			.get(room)
			.ok_or_else(|| Refusal::plain("that room is not occupied"))?;
		if held.topic == text {
			return Ok(None);
		}
		Ok(Some(authority.with_topic(held.durable_name(), text)?))
	}
	/// The name durable authority files `room` under, for its link and
	/// management identity.
	pub fn durable_name(&self, room: &RoomKey) -> Option<&str> {
		self.rooms.get(room).map(|held| held.durable_name())
	}
	/// The topic changed: the room announces it as a plain line tagged so a
	/// client that has never heard of topics still shows the sentence.
	pub fn commit_topic(&mut self, room: &RoomKey, text: &str) -> Effects<C, R> {
		let mut effects = Effects::default();
		let Some(held) = self.rooms.get_mut(room) else {
			return effects;
		};
		held.topic = text.into();
		self.broadcast(
			room,
			&mut effects,
			Notice::Topic {
				text: text.into(),
				changed: true,
			},
			None,
		);
		effects
	}
}
