//! Account for the actual retained candidate, including vector spare capacity.
use super::*;
use crate::fields::footprint::HeapBytes;

impl<K> HeapBytes for FieldKey<K> {
	fn heap_bytes(&self) -> usize {
		0
	}
}
macro_rules! scalar {
	($($kind:ty),* $(,)?) => { $(impl HeapBytes for $kind {
		fn heap_bytes(&self) -> usize { 0 }
	})* };
}
scalar!(Version, Connection, RoomKind, DirectKind);

// Destructuring makes every new owned field require an accounting decision.
macro_rules! graph {
	($kind:ident { $($owned:ident),* }; $($scalar:ident),* $(,)?) => {
		impl HeapBytes for $kind {
			fn heap_bytes(&self) -> usize {
				let Self { $($owned,)* $($scalar,)* } = self;
				let _ = ($($scalar,)*);
				0usize $(.saturating_add($owned.heap_bytes()))*
			}
		}
	};
}
graph!(Intent { accesses, directories, conversations, invitations, active,
    standing, ignored, operators, operations, peering, history_erasure, archive_shares };
	version, keep_history, connection, archive, archive_control);
graph!(Directory { id, nick, assigned_nick, standing };
	access, name, source, inbox, home, nick_allocation);
graph!(Room { id, directory, name, publication, lines, standing, draft };
		kind, source, inbox, access, accepted, public_entry, seat, topic, files, moderator, control, reconnect);
graph!(Direct { id, directory, peer, introduction, lines, draft }; kind, source, access, inbox, closed);
graph!(Introduction { registration, opening }; access, name, callback);
graph!(PublicEntry { }; access);
graph!(Invitation { id, directory, label, from }; authority, source);
graph!(ReceivedArchive { id, channel, directory, conversation, from }; kind, access, source, durable);
graph!(Peering { id, directory, name }; room, lease);
graph!(Access { id }; access, control);
graph!(PostedLine { }; id, handle);
graph!(Operations { connection }; kind, handle);
graph!(ConnectionSelection { operation, id }; gateway);
impl HeapBytes for RoomNickname {
	fn heap_bytes(&self) -> usize {
		self.text().heap_bytes()
	}
}
impl HeapBytes for InboxSelection {
	fn heap_bytes(&self) -> usize {
		match self {
			Self::Directory { id, nick, .. } => id.heap_bytes() + nick.heap_bytes(),
			Self::Room {
				id,
				directory,
				nickname,
				public_entry,
				publication,
				..
			} => {
				id.heap_bytes()
					+ directory.heap_bytes()
					+ nickname.heap_bytes()
					+ public_entry.heap_bytes()
					+ publication.heap_bytes()
			}
			Self::Direct {
				id,
				directory,
				peer,
				introduction,
				..
			} => id.heap_bytes() + directory.heap_bytes() + peer.heap_bytes() + introduction.heap_bytes(),
		}
	}
}
impl InboxSelection {
	pub fn retained_bytes(&self) -> usize {
		core::mem::size_of::<Self>() + self.heap_bytes()
	}
}
impl HeapBytes for Conversation {
	fn heap_bytes(&self) -> usize {
		match self {
			Self::Room(room) => room.heap_bytes(),
			Self::Direct(direct) => direct.heap_bytes(),
		}
	}
}
impl Intent {
	/// Physical ownership of this candidate, independent of its JSON spelling.
	pub fn retained_bytes(&self) -> usize {
		core::mem::size_of::<Self>().saturating_add(self.heap_bytes())
	}
}
impl Directory {
	/// Physical ownership, using the same exhaustive field accounting as Intent.
	pub fn retained_bytes(&self) -> usize {
		core::mem::size_of::<Self>().saturating_add(self.heap_bytes())
	}
}
