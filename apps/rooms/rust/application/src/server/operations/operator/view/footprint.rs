//! Exhaustive row destructuring makes added fields require a budget decision.
use super::rows::*;
use crate::fields::{SafeInteger, footprint::HeapBytes};
impl<const NONZERO: bool> HeapBytes for SafeInteger<NONZERO> {
	fn heap_bytes(&self) -> usize {
		0
	}
}
macro_rules! row {
	($name:ident { $($heap:ident),* ; $($scalar:ident),* }) => {
		impl HeapBytes for $name {
			fn heap_bytes(&self) -> usize {
				let Self { $($heap,)* $($scalar: _,)* } = self;
				0usize $(.saturating_add($heap.heap_bytes()))*
			}
		}
	};
}
row!(Stewardship { name, label, steward; visibility, generation, issued });
row!(Link { name, label; visibility });
row!(Registration { nick, session_id; you });
row!(Session { id, transport, nick; you });
row!(Room { id, name, origin, members; kind, proof, retained_capabilities, members_more });
row!(Member { nick, session_id, state; });
row!(Reference { id, owner, room, member, detail; kind });
row!(Trouble { source, reason; count });
