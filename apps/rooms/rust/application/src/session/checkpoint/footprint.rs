//! Owned graph capacity, without serializing or copying bearer material.
use super::{fields::*, model::*};
pub(crate) use crate::fields::footprint::HeapBytes;
impl<T: HeapBytes> HeapBytes for Presence<T> {
	fn heap_bytes(&self) -> usize {
		match self {
			Self::Value(v) => v.heap_bytes(),
			Self::Missing | Self::Null => 0,
		}
	}
}
impl HeapBytes for Answers {
	fn heap_bytes(&self) -> usize {
		Answers::heap_bytes(self)
	}
}
impl HeapBytes for Conversation {
	fn heap_bytes(&self) -> usize {
		match self {
			Self::Room(v) => v.heap_bytes(),
			Self::Direct(v) => v.heap_bytes(),
		}
	}
}
macro_rules! scalar {
	($($t:ty),* $(,)?) => { $(impl HeapBytes for $t { fn heap_bytes(&self) -> usize { 0 } })* };
}
scalar!(
	u8,
	bool,
	Reconnect,
	DmMode,
	InvitationKind,
	RoomKind,
	DirectKind,
	Operation
);
// Exhaustive destructuring makes a newly added field require an accounting decision.
macro_rules! graph {
	($t:ident { $($field:ident),* $(,)? }) => {
		impl HeapBytes for $t {
			fn heap_bytes(&self) -> usize {
				let Self { $($field),* } = self;
				0usize $(.saturating_add($field.heap_bytes()))*
			}
		}
	};
}
graph!(State {
	version,
	directories,
	conversations,
	invitations,
	active,
	standing,
	ignored,
	keep_history,
	join,
	dm_mode,
	viz_override,
	capabilities,
	peering
});
graph!(Directory {
	id,
	locator,
	home,
	reached,
	nick,
	standing
});
graph!(Room {
	kind,
	id,
	directory,
	name,
	held,
	reconnect,
	link,
	manager,
	steward,
	publication_id,
	standing,
	draft,
	bridge_intent
});
graph!(Bridge {
	scope,
	action,
	answers,
	secrets_given,
	credential_revision
});
graph!(Direct {
	kind,
	id,
	directory,
	peer,
	peer_registration_id,
	closed,
	draft
});
graph!(Invitation {
	kind,
	id,
	directory,
	locator,
	nick,
	label,
	from,
	link
});
graph!(Join { room, locator, nick });
graph!(Capabilities {
	operations,
	archive_peer
});
graph!(Credential {
	capability,
	scope,
	swiss
});
graph!(Peering {
	id,
	destination,
	source,
	name
});

#[cfg(test)]
mod tests {
	use super::super::Checkpoint;
	use super::*;
	use alloc::boxed::Box;
	use alloc::{string::String, vec::Vec};
	#[test]
	fn graph_budget_includes_spare_capacity_and_boxed_conversations() {
		let mut checkpoint = Checkpoint::empty();
		assert_eq!(checkpoint.retained_bytes(), core::mem::size_of::<Checkpoint>());
		let mut standing = String::with_capacity(4096);
		standing.push('x');
		let standing_bytes = standing.capacity();
		checkpoint.0.standing = Text::new(standing.into()).unwrap();
		let mut ignored = Vec::with_capacity(32);
		let mut ignored_text = String::with_capacity(1024);
		ignored_text.push('y');
		let ignored_bytes = ignored.capacity() * core::mem::size_of::<Field>() + ignored_text.capacity();
		ignored.push(Text::new(ignored_text.into()).unwrap());
		checkpoint.0.ignored = List::new(ignored).unwrap();
		let draft = crate::text::DocumentText::from_utf16(&[0xd800]);
		let draft_bytes = core::mem::size_of::<u16>();
		let direct = Direct {
			kind: DirectKind::Direct,
			id: Text("d".into()),
			directory: Text("r".into()),
			peer: Text("p".into()),
			peer_registration_id: Text("".into()),
			closed: false,
			draft: Text(draft),
		};
		let direct_bytes = core::mem::size_of::<Direct>()
			+ direct.id.heap_bytes()
			+ direct.directory.heap_bytes()
			+ direct.peer.heap_bytes()
			+ draft_bytes;
		checkpoint
			.0
			.conversations
			.0
			.push(Conversation::Direct(Box::new(direct)));
		let conversations_bytes = checkpoint.0.conversations.0.capacity() * core::mem::size_of::<Conversation>();
		assert_eq!(
			checkpoint.retained_bytes(),
			core::mem::size_of::<Checkpoint>() + standing_bytes + ignored_bytes + direct_bytes + conversations_bytes
		);
	}
}
