//! A room result belongs to the room row its original request named.
use super::*;
use rooms_application::server::operations::operator::verbs::GIVE_MANAGER;

/// The row field a room result lands in, from the route that produced it.
#[derive(Clone, Copy)]
enum Landing {
	Moderator,
	Access,
}
impl Request<'_> {
	/// One original request and the receipt's first target decide the whole
	/// check. No seat is read, so a session between seats saves the result it
	/// asked for. The returned pair is the receipt's original target and the
	/// custody held at its coordinate.
	pub(super) fn room_origin<'r>(
		&self,
		record: &'r MetadataRecord,
		receipt: &'r custody::EffectReceipt<records::Metadata>,
		candidate: &workspace::Intent,
	) -> Result<Option<OriginTargets<'r>>> {
		if self.created {
			return Ok(None);
		}
		let mut roles = self.selections.iter().filter(|selection| {
			matches!(
				selection.destination.role,
				custody::Role::RoomAccess | custody::Role::RoomControl
			)
		});
		let Some(selection) = roles.next() else { return Ok(None) };
		if roles.next().is_some() {
			return Err(refuse("one room result selects one field"));
		}
		let original = original_text(text(self.intent)?)?;
		let (landing, id) = match (selection.destination.role, original.as_slice()) {
			// The manager result finds its row by reading seats after the commit.
			(custody::Role::RoomControl, [_, _, route, _, action, _])
				if text(route)? == "operator" && text(action)? == GIVE_MANAGER =>
			{
				return Ok(None);
			}
			(custody::Role::RoomAccess, [_, _, route, room]) => match text(route)? {
				"issueRoomModerator" => (Landing::Moderator, text(room)?),
				"ensureRoomLink" => (Landing::Access, text(room)?),
				_ => return Err(refuse("room result differs from its original request")),
			},
			_ => return Err(refuse("room result differs from its original request")),
		};
		let current = record
			.intent
			.room(id)
			.ok_or_else(|| refuse("original room was removed"))?;
		let next = candidate
			.room(id)
			.ok_or_else(|| refuse("room result must retain its original room"))?;
		let destination = selection.destination;
		let holds = |key: Option<custody::FieldKey<custody::RoomAccess>>| {
			key.is_some_and(|key| {
				key.slot() == destination.key.slot() && key.generation() == destination.key.generation()
			})
		};
		let (named, other) = match landing {
			Landing::Moderator => (next.moderator, next.access),
			Landing::Access => (next.access, next.moderator),
		};
		if !holds(named) {
			return Err(refuse(if holds(other) {
				"room result is saved into a field its request does not name"
			} else {
				"room result is not saved into the room its request named"
			}));
		}
		if holds(other) {
			return Err(refuse("room result is held by two fields of its room"));
		}
		if candidate.coordinates().filter(|held| *held == destination).count() != 1 {
			return Err(refuse("room result is held by another room"));
		}
		let original = first_target(receipt, "room receipt has no original target")?;
		let coordinate = original.coordinate();
		let held = match landing {
			Landing::Moderator => current
				.control
				.map(|key| Coordinate::new(custody::Role::RoomControl, key)),
			Landing::Access => current.link_target(),
		};
		if held != Some(coordinate) {
			return Err(refuse(REPLACED));
		}
		// A held manager link stays in the candidate. A replaced entrance is
		// the field this result saves.
		if coordinate.role == custody::Role::RoomControl && next.control != current.control {
			return Err(refuse("room result must keep the manager link its request used"));
		}
		held_at(record, original, "original room target custody is absent").map(Some)
	}
}
