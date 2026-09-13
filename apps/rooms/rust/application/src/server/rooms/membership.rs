//! What one live seat may ask of its room. The capability identifies the
//! membership; no nickname or calling connection authorizes an act, and an
//! observer seat may watch but not speak.
use super::{
	Effects, HISTORY_ANSWERED, InvitationKey, LineKey, MAX_AWAY, MAX_ROOM_INVITATIONS, MembershipKey, Refusal, RoomKey,
	Rooms, UploadKey,
	entrance::{Departure, Entrance, Gate},
	notice::Notice,
	state::{Invitation, Line, Upload},
};
use crate::{
	failure::FailureCode,
	files::FileDescription,
	room::{
		line::MAX_LINE_BYTES,
		message::{ChangeKind, LineId},
		policy::MembershipKind,
	},
	server::history::{self, KeptLine, LINES_KEPT},
};
use alloc::{format, string::String, sync::Arc, vec::Vec};

type Members<C, R> = alloc::collections::BTreeMap<RoomKey, super::state::Room<C, R>>;

/// The seat a verb acts for, borrowing the rooms alone so the store and the
/// counters beside them stay free to change.
fn seated<'a, C: Copy + PartialEq, R>(
	rooms: &'a Members<C, R>,
	room: &RoomKey,
	membership: MembershipKey,
) -> Result<&'a super::state::Member<C, R>, Refusal> {
	rooms
		.get(room)
		.and_then(|room| room.member(membership))
		.ok_or_else(|| Refusal::coded(FailureCode::NotRoomMember, "this room membership has ended"))
}
fn participant<'a, C: Copy + PartialEq, R>(
	rooms: &'a Members<C, R>,
	room: &RoomKey,
	membership: MembershipKey,
) -> Result<&'a super::state::Member<C, R>, Refusal> {
	let member = seated(rooms, room, membership)?;
	if member.kind != MembershipKind::Participant {
		return Err(Refusal::coded(
			FailureCode::ReadOnlyMembership,
			"this observer membership cannot speak in the room",
		));
	}
	Ok(member)
}

impl<C: Copy + Ord, R: Clone> Rooms<C, R> {
	pub fn membership_kind(&self, room: &RoomKey, membership: MembershipKey) -> Result<MembershipKind, Refusal> {
		Ok(seated(&self.rooms, room, membership)?.kind)
	}

	fn next_line(&mut self, room: &RoomKey) -> Result<LineId, Refusal> {
		let held = self.rooms.get_mut(room).expect("a seated room is live");
		let id = LineId::new(held.next_line).ok_or_else(|| Refusal::plain("this room has said all it can"))?;
		held.next_line += 1;
		Ok(id)
	}

	/// Say one line. The adapter's line actor is named by the answered key.
	pub fn post(
		&mut self,
		room: &RoomKey,
		membership: MembershipKey,
		text: &str,
		now: u64,
	) -> Result<(LineKey, super::Mutation<C, R>), Refusal> {
		self.post_with_previews(room, membership, text, crate::open_graph::Selection::default(), now)
	}

	pub fn post_with_previews(
		&mut self,
		room: &RoomKey,
		membership: MembershipKey,
		text: &str,
		previews: crate::open_graph::Selection,
		now: u64,
	) -> Result<(LineKey, super::Mutation<C, R>), Refusal> {
		let member = participant(&self.rooms, room, membership)?;
		if text.len() > MAX_LINE_BYTES {
			return Err(Refusal::plain(format!("a line may be at most {MAX_LINE_BYTES} bytes")));
		}
		let nick = member.nick.clone();
		self.said(room, nick, text, previews, now, Vec::new())
	}

	/// Publish every file staged by this membership as one line. Wall time
	/// dates the history entry; monotonic time governs upload lifetimes.
	pub fn post_files(
		&mut self,
		room: &RoomKey,
		membership: MembershipKey,
		caption: &str,
		wall_ms: u64,
		monotonic_ms: u64,
	) -> Result<(LineKey, super::Mutation<C, R>), Refusal> {
		self.post_files_with_previews(
			room,
			membership,
			caption,
			crate::open_graph::Selection::default(),
			wall_ms,
			monotonic_ms,
		)
	}

	pub fn post_files_with_previews(
		&mut self,
		room: &RoomKey,
		membership: MembershipKey,
		caption: &str,
		previews: crate::open_graph::Selection,
		wall_ms: u64,
		monotonic_ms: u64,
	) -> Result<(LineKey, super::Mutation<C, R>), Refusal> {
		self.file_time(monotonic_ms)?;
		let member = participant(&self.rooms, room, membership)?;
		if caption.len() > MAX_LINE_BYTES {
			return Err(Refusal::plain(format!(
				"a caption may be at most {MAX_LINE_BYTES} bytes"
			)));
		}
		let nick = member.nick.clone();
		let files = self.files.post(&member.files).map_err(Refusal::plain)?;
		if files.is_empty() {
			return Err(Refusal::coded(FailureCode::UploadIncomplete, "no files are staged"));
		}
		let caption: String = if caption.is_empty() {
			files
				.first()
				.map(|file| file.description().name().into())
				.unwrap_or_default()
		} else {
			caption.into()
		};
		let previews = previews.retained_for(&caption);
		self.said(room, nick, &caption, previews, wall_ms, files)
	}

	fn said(
		&mut self,
		room: &RoomKey,
		nick: String,
		text: &str,
		previews: crate::open_graph::Selection,
		now: u64,
		mut files: Vec<crate::files::HostedFile>,
	) -> Result<(LineKey, super::Mutation<C, R>), Refusal> {
		let id = self.next_line(room)?;
		let blobs: Vec<_> = files.iter().map(|file| file.blob()).collect();
		let line = {
			let held = &self.rooms[room];
			self.files
				.line(&held.files, id, nick.clone(), &mut files)
				.map_err(Refusal::plain)?
		};
		// The line's one body: the history row, the editable row, and every
		// member's notice share it, so a room of members costs one copy.
		let shown = Arc::new(KeptLine {
			from: nick,
			text: text.into(),
			previews,
			at: now,
		});
		let mut effects = Effects::default();
		let mut mutation = super::Mutation::default();
		let kept = match self.history.as_mut() {
			Some(history) => {
				let recorded = history.record(room.as_str(), shown.clone()).map_err(Refusal::plain)?;
				// The editable window is the history the room keeps: a row
				// leaving the index takes its line with it, and a room
				// evicted whole takes every line it still answered.
				if let Some(retired) = recorded.retired
					&& let Some(line) = self.kept_lines.get(&retired).copied()
				{
					self.retire_line(line);
				}
				if let history::Persist::Append {
					evicted: Some(evicted), ..
				} = &recorded.persist
				{
					let lines: Vec<LineKey> = self
						.rooms
						.get(&RoomKey::from_text(evicted))
						.map(|room| room.lines.iter().copied().collect())
						.unwrap_or_default();
					for line in lines {
						self.retire_line(line);
					}
				}
				mutation.persist = Some(recorded.persist);
				Some(recorded.token)
			}
			None => {
				// Without history the window closes on its own count, oldest
				// first, at the size a kept room's would.
				let oldest = self.rooms[room]
					.lines
					.first()
					.copied()
					.filter(|_| self.rooms[room].lines.len() >= LINES_KEPT);
				if let Some(oldest) = oldest {
					self.retire_line(oldest);
				}
				None
			}
		};
		let key = LineKey(self.next_id());
		self.lines.insert(
			key,
			Line {
				room: room.clone(),
				line,
				shown: shown.clone(),
				kept,
			},
		);
		if let Some(token) = kept {
			self.kept_lines.insert(token, key);
		}
		self.rooms
			.get_mut(room)
			.expect("a seated room is live")
			.lines
			.insert(key);
		self.broadcast(
			room,
			&mut effects,
			Notice::Line {
				line: shown,
				marker: Some((ChangeKind::Said, id)),
				files: blobs,
			},
			None,
		);
		mutation.effects = effects;
		Ok((key, mutation))
	}

	/// Admit one file and name the upload the adapter mints for it.
	pub fn attach(
		&mut self,
		room: &RoomKey,
		membership: MembershipKey,
		description: FileDescription,
		monotonic_ms: u64,
	) -> Result<UploadKey, Refusal> {
		self.file_time(monotonic_ms)?;
		let member = participant(&self.rooms, room, membership)?;
		let uploader = member.connection;
		let upload = self.files.attach(&member.files, description).map_err(Refusal::plain)?;
		let key = UploadKey(self.next_id());
		self.uploads.insert(
			key,
			Upload {
				room: room.clone(),
				upload,
				uploader,
			},
		);
		Ok(key)
	}

	pub fn typing(&self, room: &RoomKey, membership: MembershipKey, on: bool) -> Result<Effects<C, R>, Refusal> {
		let member = participant(&self.rooms, room, membership)?;
		let mut effects = Effects::default();
		self.broadcast(
			room,
			&mut effects,
			Notice::Typing {
				nick: member.nick.clone(),
				on,
			},
			Some(member.connection),
		);
		Ok(effects)
	}

	/// The last lines the server kept for this room, oldest first, borrowed
	/// so the adapter encodes each straight from the row the index shares.
	pub fn history(
		&self,
		room: &RoomKey,
		membership: MembershipKey,
	) -> Result<impl Iterator<Item = &KeptLine> + '_, Refusal> {
		seated(&self.rooms, room, membership)?;
		let Some(history) = &self.history else {
			return Err(Refusal::plain("room membership has no method history"));
		};
		Ok(history.read(room.as_str(), HISTORY_ANSWERED))
	}

	pub fn away(&mut self, room: &RoomKey, membership: MembershipKey, why: &str) -> Result<Effects<C, R>, Refusal> {
		seated(&self.rooms, room, membership)?;
		if why.encode_utf16().count() > MAX_AWAY {
			return Err(Refusal::plain(format!(
				"an away reason may be at most {MAX_AWAY} characters"
			)));
		}
		let held = self.rooms.get_mut(room).expect("seated");
		let member = held.member_mut(membership).expect("seated");
		if member.away == why {
			return Ok(Effects::default());
		}
		member.away = why.into();
		let nick = member.nick.clone();
		let mut effects = Effects::default();
		self.broadcast(room, &mut effects, Notice::Away { nick, why: why.into() }, None);
		Ok(effects)
	}

	pub fn leave(&mut self, room: &RoomKey, membership: MembershipKey) -> Result<Effects<C, R>, Refusal> {
		seated(&self.rooms, room, membership)?;
		Ok(self.leave_member(room, membership, None, Departure::Left))
	}

	/// Mint one invitation into this room generation, carrying the minter's
	/// say-so for as long as the minting membership lasts.
	pub fn mint_invitation(
		&mut self,
		room: &RoomKey,
		membership: MembershipKey,
		kind: MembershipKind,
	) -> Result<InvitationKey, Refusal> {
		let member = participant(&self.rooms, room, membership)?;
		let minter = member.connection;
		let held = &self.rooms[room];
		if held.invitations.len() >= MAX_ROOM_INVITATIONS {
			return Err(Refusal::plain(format!(
				"this room already holds {MAX_ROOM_INVITATIONS} live invitations"
			)));
		}
		let generation = held.entry_id.clone();
		let key = InvitationKey(self.next_id());
		self.invitations.insert(
			key,
			Invitation {
				room: room.clone(),
				generation,
				minter,
				kind,
				admission: Default::default(),
			},
		);
		self.rooms.get_mut(room).expect("seated").invitations.insert(key);
		Ok(key)
	}

	/// Claim an invitation with a receipt. The first receipt wins; the same
	/// receipt may claim again after a lost answer, another is refused.
	pub fn claim_invitation(&mut self, key: InvitationKey, receipt: &str) -> Result<Entrance, Refusal> {
		let ended = || Refusal::plain("this room invitation has ended");
		let invitation = self.invitations.get_mut(&key).ok_or_else(ended)?;
		let current = self
			.rooms
			.get(&invitation.room)
			.is_some_and(|room| room.entry_id == invitation.generation);
		if !current {
			return Err(ended());
		}
		invitation.admission.claim(receipt).map_err(Refusal::plain)?;
		Ok(Entrance {
			room: invitation.room.clone(),
			durable: None,
			kind: invitation.kind,
			gate: Gate::Invitation(key),
		})
	}
}
