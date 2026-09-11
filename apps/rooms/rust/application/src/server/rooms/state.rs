//! What one live room holds, and the keys the adapter's actors are named by.
use super::MAX_ROOM_MEMBERS;
use crate::{
	directory::{registration::Id, OriginProof, PublicationKind, RoomInfo},
	fields::{Nullable, SafeInteger, Text},
	files::{FileMember, FileRoom},
	room::{
		line::MAX_LINE_BYTES,
		policy::{MembershipKind, RoomPolicy},
	},
	server::history::Token,
};
use alloc::{collections::BTreeSet, string::String, vec::Vec};

/// The key a room lives under: a public name folded and prefixed with `#`,
/// or a managed room's opaque `~` id. Two namespaces in one table have to be
/// told apart by construction rather than by hoping the shapes never meet.
pub type RoomKey = String;

pub fn public_key(name: &str) -> RoomKey {
	let mut key = String::with_capacity(name.len() + 1);
	key.push('#');
	key.push_str(&name.to_lowercase());
	key
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
	pub files: FileMember,
}

pub(super) struct Room<C, R> {
	/// Opaque identity for this exact public-room generation.
	pub entry_id: Id,
	/// The casing the opener chose.
	pub name: String,
	pub key: RoomKey,
	pub policy: RoomPolicy,
	pub members: Vec<Member<C, R>>,
	pub invitations: BTreeSet<super::InvitationKey>,
	/// The connection that opened the room; an empty room it opened goes
	/// with it.
	pub lifetime_owner: C,
	/// Names the next line this room generation makes.
	pub next_line: u64,
	pub topic: String,
	pub files: FileRoom,
}

impl<C: Copy + PartialEq, R> Room<C, R> {
	/// The name durable authority files this room under: a managed room's
	/// opaque key, or a public room's display name.
	pub fn durable_name(&self) -> &str {
		if self.key.starts_with('#') {
			&self.name
		} else {
			&self.key
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
			count: Nullable::Value(SafeInteger::new(self.members.len() as u64).expect("a bounded roster")),
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

/// Who is present, said to the one reader who just arrived. A sentence,
/// because it is read rather than parsed: the names travel beside it.
pub fn roster_said(names: &[String]) -> String {
	if names.len() == 1 {
		return "Nobody else is in the room.".into();
	}
	let (last, rest) = names.split_last().expect("a roster names its arrival");
	let mut said = rest.join(", ");
	said.push_str(" and ");
	said.push_str(last);
	said.push_str(" are in the room.");
	said
}

pub(super) struct Line {
	pub room: RoomKey,
	pub line: crate::files::HostedLine,
	pub kept: Option<Token>,
}

pub(super) struct Upload<C> {
	pub room: RoomKey,
	pub upload: crate::files::Upload,
	pub uploader: C,
}

pub(super) struct Invitation<C> {
	pub room: RoomKey,
	pub generation: Id,
	pub minter: C,
	pub kind: MembershipKind,
	pub active: bool,
	pub admission: crate::server::invitation::Admission,
}
