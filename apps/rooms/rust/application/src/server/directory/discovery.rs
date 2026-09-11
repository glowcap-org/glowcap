//! The watch baseline a directory answers: the rooms it lists and the members
//! it has registered, under one shared row ceiling. The snapshot type and the
//! shape are the client's own, so the wire has one shape with one authority.
use super::registry::Registry;
use crate::directory::MAX_ROWS;
pub use crate::directory::{Shape, Snapshot};
use alloc::vec::Vec;

/// One atomic baseline. Rooms and live registrations share the discovery
/// ceiling; `omitted` tells a client to treat the view as truncated rather
/// than mistake a dropped notification for a complete peer set. `rooms` are
/// the listed rooms the server hosts, in the order it lists them.
pub(super) fn snapshot<C: Copy + Ord, R: Clone>(
	registry: &Registry<C, R>,
	rooms: impl Iterator<Item = crate::directory::RoomInfo>,
	_shape: Shape,
) -> Snapshot {
	let mut omitted = 0u64;
	let mut listed = Vec::new();
	for room in rooms {
		if listed.len() == MAX_ROWS {
			omitted += 1;
		} else {
			listed.push(room);
		}
	}
	let remaining = MAX_ROWS.saturating_sub(listed.len());
	let mut peers = Vec::with_capacity(remaining.min(registry.len()));
	for member in registry.members() {
		if peers.len() == remaining {
			omitted += 1;
		} else {
			peers.push(member);
		}
	}
	Snapshot {
		rooms: listed,
		peers,
		omitted,
	}
}
