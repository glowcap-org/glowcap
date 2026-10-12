//! What one live room holds, and the keys the adapter's actors are named by.
use super::MAX_ROOM_MEMBERS;
use crate::{
	directory::{OriginProof, PublicationKind, RoomInfo, registration::Id},
	fields::{Nullable, SafeInteger, Text},
	files::{FileMember, FileRoom},
	room::{
		line::MAX_LINE_BYTES,
		policy::{MembershipKind, RoomPolicy},
	},
	server::history::{KeptLine, Token},
};
use alloc::{
	collections::{BTreeSet, VecDeque},
	string::String,
	sync::Arc,
	vec::Vec,
};

/// The key a room lives under. Two namespaces share one table, a listed
/// room's public name and a managed or private room's opaque id, and the
/// variant is what tells them apart. The text inside carries the same
/// mark, `#` before a folded public name and the `~` a recovery key
/// already starts with, so a history file names the room by `as_str` with
/// no second form to keep aligned.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum RoomKey {
	/// A listed room's public name, folded so `Garden` and `garden` are one
	/// room, behind a `#`.
	Public(String),
	/// A managed room's id or a private room's recovery key, exactly as the
	/// authority or the opener issued it, in the form `RecoveryKey::accepts`.
	Managed(String),
}

impl RoomKey {
	pub fn public(name: &str) -> Self {
		let mut key = String::with_capacity(name.len() + 1);
		key.push('#');
		key.push_str(&folded(name));
		Self::Public(key)
	}
	pub fn managed(id: &str) -> Self {
		Self::Managed(id.into())
	}
	/// The key a history row names, read back: the text `as_str` gave when
	/// the room was recorded, so the mark says which namespace it is.
	pub(super) fn from_text(text: &str) -> Self {
		if text.starts_with('#') {
			Self::Public(text.into())
		} else {
			Self::Managed(text.into())
		}
	}
	pub fn is_public(&self) -> bool {
		matches!(self, Self::Public(_))
	}
	/// The key's text, what the history index files the room under.
	pub fn as_str(&self) -> &str {
		match self {
			Self::Public(key) | Self::Managed(key) => key,
		}
	}
}

impl core::fmt::Display for RoomKey {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(self.as_str())
	}
}

/// A public name as the listing index holds it: case folded, so one name
/// is one listed room.
pub(super) fn folded(name: &str) -> String {
	name.to_lowercase()
}

macro_rules! key {
	($name:ident, $doc:literal) => {
		#[doc = $doc]
		#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
		pub struct $name(pub(super) u64);
	};
}
key!(MembershipKey, "One exact live seat.");
impl MembershipKey {
	/// The seat's number, for an id that names it outside the policy.
	pub fn raw(self) -> u64 {
		self.0
	}
}
key!(LineKey, "One line capability's state.");
key!(UploadKey, "One upload in flight.");
key!(InvitationKey, "One invitation minted into a room generation.");

pub(super) struct Member<C, R> {
	pub key: MembershipKey,
	pub nick: String,
	pub inbox: R,
	pub connection: C,
	pub kind: MembershipKind,
	/// Why this member has stepped away, empty while they are here.
	pub away: String,
	/// Coalesce identical typing until its display lease is due for renewal.
	pub typing_until: core::cell::Cell<u64>,
	pub files: FileMember,
}

pub(super) struct OfflineName {
	pub nick: String,
	/// Computed once on disconnect. Joins compare keys without folding every row.
	key: String,
}

pub(super) struct Room<C, R> {
	/// Opaque identity for this exact public-room generation.
	pub entry_id: Id,
	/// The casing the opener chose.
	pub name: String,
	pub key: RoomKey,
	pub policy: RoomPolicy,
	pub members: Vec<Member<C, R>>,
	/// Disconnected display names only, bounded oldest first.
	/// No seat, registration, callback, or other authority survives here. The
	/// queue dies with this room generation. Removing it loses offline presence
	/// on a fresh subscription while existing readers still retain those names.
	pub offline: VecDeque<OfflineName>,
	pub invitations: BTreeSet<super::InvitationKey>,
	/// The lines this generation still answers edits on, oldest first, so
	/// the editable window closes from its oldest end.
	pub lines: BTreeSet<super::LineKey>,
	/// The connection that opened the room. An empty room it opened goes
	/// with it.
	pub lifetime_owner: C,
	/// Names the next line this room generation makes.
	pub next_line: u64,
	pub topic: String,
	pub files: FileRoom,
}

impl<C: Copy + PartialEq, R> Room<C, R> {
	pub fn forget_offline(&mut self, nick: &str) -> Option<String> {
		if self.offline.is_empty() {
			return None;
		}
		let key = folded(nick);
		let index = self.offline.iter().position(|name| name.key == key)?;
		self.offline.remove(index).map(|name| name.nick)
	}
	pub fn remember_offline(&mut self, nick: String) -> Option<String> {
		// Every successful subscribe removes its old offline entry first.
		let evicted = if self.offline.len() == super::MAX_ROOM_OFFLINE {
			self.offline.pop_front()
		} else {
			None
		};
		self.offline.push_back(OfflineName {
			key: folded(&nick),
			nick,
		});
		evicted.map(|name| name.nick)
	}
	/// The name durable authority files this room under: a managed room's
	/// opaque key, or a public room's display name.
	pub fn durable_name(&self) -> &str {
		if self.key.is_public() {
			&self.name
		} else {
			self.key.as_str()
		}
	}
	pub fn member_of(&self, connection: C) -> Option<&Member<C, R>> {
		self.members.iter().find(|member| member.connection == connection)
	}
	pub fn member_named(&self, nick: &str) -> Option<&Member<C, R>> {
		let key = nick.to_lowercase();
		self.members.iter().find(|member| member.nick.to_lowercase() == key)
	}
	pub fn member(&self, key: super::MembershipKey) -> Option<&Member<C, R>> {
		self.members.iter().find(|member| member.key == key)
	}
	pub fn member_mut(&mut self, key: super::MembershipKey) -> Option<&mut Member<C, R>> {
		self.members.iter_mut().find(|member| member.key == key)
	}
	/// The public entry a directory lists this room as.
	pub fn info(&self) -> RoomInfo {
		RoomInfo {
			id: Text(self.entry_id.as_str().into()),
			name: Text(self.name.as_str().into()),
			kind: PublicationKind::Local,
			count: Nullable::Value(roster_count(self.members.len())),
			origin: Text("".into()),
			proof: OriginProof::Local,
			offers: match self.policy.public_membership() {
				Some(kind) => Nullable::Value(kind),
				None => Nullable::Null,
			},
		}
	}
	/// The roster a successful subscribe sends, before any mutation. A
	/// same-connection re-entry replaces its row and costs no extra seat.
	pub fn roster_for(
		&self,
		connection: C,
		nick: &str,
		replacing: Option<super::MembershipKey>,
	) -> Option<Vec<String>> {
		let mut names: Vec<String> = self
			.members
			.iter()
			.filter(|member| member.connection != connection && Some(member.key) != replacing)
			.map(|member| member.nick.clone())
			.collect();
		names.push(nick.into());
		if names.len() > MAX_ROOM_MEMBERS || roster_said(&names).len() > MAX_LINE_BYTES {
			return None;
		}
		Some(names)
	}
}

/// A roster count as the listing carries it. Membership admission bounds the
/// count by the room's ceiling, so it is always inside the safe range.
pub(crate) fn roster_count(count: usize) -> SafeInteger {
	#[expect(
		clippy::expect_used,
		reason = "membership admission bounds a roster by MAX_MEMBERS, far inside 2^53"
	)]
	SafeInteger::new(count as u64).expect("a bounded roster")
}

/// Who is present, said to the one reader who just arrived. A sentence,
/// because it is read rather than parsed: the names travel beside it.
pub fn roster_said(names: &[String]) -> String {
	let Some((last, rest)) = names.split_last().filter(|(_, rest)| !rest.is_empty()) else {
		return "Nobody else is in the room.".into();
	};
	let mut said = rest.join(", ");
	said.push_str(" and ");
	said.push_str(last);
	said.push_str(" are in the room.");
	said
}

/// One line a room still answers edits on. `shown` is the line as members
/// last heard it, the same row the history index keeps when the server
/// keeps any, so an edit reads its previews and time from one place.
pub(super) struct Line {
	pub room: RoomKey,
	pub line: crate::files::HostedLine,
	pub shown: Arc<KeptLine>,
	pub kept: Option<Token>,
}

pub(super) struct Upload<C> {
	pub room: RoomKey,
	pub upload: crate::files::Upload,
	pub uploader: C,
}

/// One live invitation. A retired invitation has no row: absence is the
/// same fact, and every reader treats it so.
pub(super) struct Invitation<C> {
	pub room: RoomKey,
	pub generation: Id,
	pub minter: C,
	pub kind: MembershipKind,
	pub admission: crate::server::invitation::Admission,
}
