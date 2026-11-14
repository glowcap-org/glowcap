//! The heap each operator view row owns.
use super::rows::*;
use crate::fields::{
	SafeInteger,
	footprint::{HeapBytes, graph},
};
impl<const NONZERO: bool> HeapBytes for SafeInteger<NONZERO> {
	fn heap_bytes(&self) -> usize {
		0
	}
}
graph!(Stewardship { name, label, steward, manager; visibility, generation, bridged });
graph!(Link { name, label; visibility });
graph!(Registration { nick, session_id; you });
graph!(Session { id, transport, nick; you });
graph!(Room { id, name, origin, members; kind, proof, retained_capabilities, members_more });
graph!(Member { nick, session_id, state; });
graph!(Reference { id, owner, room, member, detail; kind });
graph!(Trouble { source, reason; count });
