//! What holding a line's reference lets somebody do to it, and the same one
//! level up for the room's subject. Neither asks who is calling: possession
//! already answered the question, so the authority can be passed on.
use super::{Effects, LineKey, Refusal, RoomKey, Rooms, notice::Notice};
use crate::{
	files::FileLineError,
	room::{ArgumentView, message::ChangeKind, subject::Subject},
	server::{
		history::{KeptLine, Persist},
		links::Authority,
	},
};
use alloc::{sync::Arc, vec::Vec};

impl<C: Copy + Ord, R: Clone> Rooms<C, R> {
	/// Dispatch a line verb. The staged files a refile adds are the calling
	/// connection's own in the line's room, even when the line was handed to
	/// that connection by somebody else. A line whose row is gone, withdrawn
	/// or past the window the room keeps, answers every verb the same way.
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
			return Err(Refusal::plain("that line can no longer be changed"));
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
				FileLineError::Line(error) => Refusal::plain(error),
				FileLineError::Files(error) => Refusal::plain(error),
			})?;
		let Some(change) = change else {
			return Ok(super::Mutation::default());
		};
		let (room, id, kind) = (line.room.clone(), change.id, change.kind);
		let previews = if kind == ChangeKind::Withdrawn {
			crate::open_graph::Selection::default()
		} else {
			line.shown.previews.retained_for(change.text)
		};
		// The changed line's one body, shared the way the said line's was.
		let shown = Arc::new(KeptLine {
			from: change.from.into(),
			text: change.text.into(),
			previews,
			at: line.shown.at,
		});
		let blobs: Vec<_> = change.files.iter().map(|file| file.blob()).collect();
		let kept = line.kept;
		line.shown = shown.clone();
		let mut effects = Effects::default();
		let mut mutation = super::Mutation::default();
		if let (Some(history), Some(token)) = (self.history.as_mut(), kept) {
			let persist: Option<Persist> = match kind {
				ChangeKind::Withdrawn => history.forget(room.as_str(), token),
				ChangeKind::Edited | ChangeKind::Refiled => history
					.replace(room.as_str(), token, shown.clone())
					.map_err(Refusal::plain)?,
				ChangeKind::Said => None,
			};
			mutation.persist = persist;
		}
		if kind == ChangeKind::Withdrawn {
			// A withdrawn line has no history row and nothing left to change,
			// so its row goes with the text.
			self.retire_line(key);
		}
		self.broadcast(
			&room,
			&mut effects,
			Notice::Line {
				line: shown,
				marker: Some((kind, id)),
				files: blobs,
			},
			None,
		);
		mutation.effects = effects;
		Ok(mutation)
	}

	/// Whether a line still answers its holders: a withdrawn line, or one
	/// past the window the room keeps, refuses every change.
	pub fn line_answers(&self, key: LineKey) -> bool {
		self.lines.contains_key(&key)
	}
	/// The authoritative notification identity returned with this exact line.
	pub fn line_id(&self, key: LineKey) -> Option<crate::room::message::LineId> {
		self.lines.get(&key).map(|line| line.line.id())
	}

	/// The authority successor a subject change persists first, when the room
	/// has a durable name. `Ok(None)` when the subject already stands so.
	pub fn prepare_subject(
		&self,
		room: &RoomKey,
		subject: &Subject,
		authority: &Authority,
	) -> Result<Option<Option<Authority>>, Refusal> {
		let held = self
			.rooms
			.get(room)
			.ok_or_else(|| Refusal::plain("that room is not occupied"))?;
		if held.subject == *subject {
			return Ok(None);
		}
		Ok(Some(authority.with_subject(held.durable_name(), subject)?))
	}
	/// The name durable authority files `room` under, for its link and
	/// management identity.
	pub fn durable_name(&self, room: &RoomKey) -> Option<&str> {
		self.rooms.get(room).map(|held| held.durable_name())
	}
	/// The subject changed: the room announces it as a plain line tagged so
	/// a client that has never heard of subjects still shows the sentence.
	pub fn commit_subject(&mut self, room: &RoomKey, subject: Subject) -> Effects<C, R> {
		let mut effects = Effects::default();
		// A queued change may find the subject already set by the one before it.
		let Some(held) = self.rooms.get_mut(room).filter(|held| held.subject != subject) else {
			return effects;
		};
		held.subject = subject.clone();
		self.broadcast(room, &mut effects, Notice::Subject { subject, changed: true }, None);
		effects
	}
}
