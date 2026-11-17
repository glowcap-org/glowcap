//! The room a manager recovery is admitted for. The request carries this
//! witness instead of a management identity: the worker reads the identity
//! from the witnessed seat itself, and the result lands only in that row.
use super::{
	custody::{self, FieldKey},
	workspace::{Id, PublicEntry, Room},
};
use crate::fields::Text;
use serde::{Deserialize, Serialize};

/// Every fact of the row that decides which room the recovery belongs to. A
/// replaced row, seat, directory or entrance no longer matches. The runtime
/// reads only `id` and `seat`, and asks the methods for the rest.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Witness {
	pub id: Id,
	directory: Id,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	source: Option<FieldKey<custody::SessionAccess>>,
	pub seat: FieldKey<custody::RoomSeat>,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	access: Option<FieldKey<custody::RoomAccess>>,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	accepted: Option<FieldKey<custody::AcceptedAccess>>,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	public_entry: Option<PublicEntry>,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	publication: Option<Text<128, true>>,
}
impl Witness {
	pub fn parse(raw: &str) -> Result<Self, serde_json::Error> {
		crate::fields::json_object(raw)
	}
	/// The row still stands as witnessed, apart from its seat. Landing allows
	/// the seat to be lost or replaced when an entrance carries the room.
	pub fn same_room(&self, room: &Room) -> bool {
		room.id == self.id
			&& room.directory == self.directory
			&& room.source == self.source
			&& room.access == self.access
			&& room.accepted == self.accepted
			&& room.public_entry == self.public_entry
			&& room.publication == self.publication
	}
	/// The complete current row, seat included, as admission requires.
	pub fn matches(&self, room: &Room) -> bool {
		self.same_room(room) && room.seat == Some(self.seat)
	}
	/// The one coordinate that holds the room: its entrance, else its seat.
	pub fn basis(&self) -> custody::Coordinate {
		self.entrance()
			.unwrap_or_else(|| custody::Coordinate::new(custody::Role::RoomSeat, self.seat))
	}
	/// The entrance coordinate, when the row has exactly one.
	pub fn entrance(&self) -> Option<custody::Coordinate> {
		match (self.access, self.accepted, self.public_entry.as_ref()) {
			(Some(key), None, None) => Some(custody::Coordinate::new(custody::Role::RoomAccess, key)),
			(None, Some(key), None) => Some(custody::Coordinate::new(custody::Role::AcceptedAccess, key)),
			(None, None, Some(entry)) => Some(custody::Coordinate::new(custody::Role::DirectoryAccess, entry.access)),
			_ => None,
		}
	}
	pub fn seat_coordinate(&self) -> custody::Coordinate {
		custody::Coordinate::new(custody::Role::RoomSeat, self.seat)
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	const KEY: &str = "00000000000000010000000000000001";
	const OTHER: &str = "00000000000000020000000000000001";

	fn room(seat: &str, access: Option<&str>) -> Room {
		serde_json::from_value(serde_json::json!({
			"kind": "room", "id": "room", "directory": "directory", "name": "room",
			"access": access, "seat": seat, "reconnect": "requested", "standing": null, "draft": ""
		}))
		.unwrap()
	}
	fn parse(value: serde_json::Value) -> Witness {
		Witness::parse(&serde_json::to_string(&value).unwrap()).unwrap()
	}
	fn witness(seat: &str, access: Option<&str>) -> Witness {
		parse(serde_json::json!({"id": "room", "directory": "directory", "seat": seat, "access": access}))
	}

	#[test]
	fn a_witness_names_the_complete_row_and_rejects_anything_else() {
		assert!(
			Witness::parse(
				&serde_json::to_string(
					&serde_json::json!({"id": "room", "directory": "directory", "seat": KEY, "extra": 1})
				)
				.unwrap()
			)
			.is_err()
		);
		assert!(Witness::parse("[]").is_err());
		let held = witness(KEY, Some(KEY));
		assert!(held.matches(&room(KEY, Some(KEY))));
		assert!(
			!held.matches(&room(OTHER, Some(KEY))),
			"a replaced seat no longer matches"
		);
		assert!(
			held.same_room(&room(OTHER, Some(KEY))),
			"landing tolerates a replaced seat"
		);
		assert!(
			!held.same_room(&room(KEY, Some(OTHER))),
			"a replaced entrance is another room"
		);
		assert!(!held.same_room(&room(KEY, None)));
	}
	#[test]
	fn the_room_id_and_the_publication_each_decide_the_room() {
		let held = parse(serde_json::json!({
			"id": "room", "directory": "directory", "seat": KEY, "access": null,
			"publicEntry": {"access": OTHER}, "publication": "published"
		}));
		let row = |id: &str, publication: &str| -> Room {
			serde_json::from_value(serde_json::json!({
				"kind": "room", "id": id, "directory": "directory", "name": "room", "access": null,
				"publicEntry": {"access": OTHER}, "publication": publication, "seat": KEY,
				"reconnect": "requested", "standing": null, "draft": ""
			}))
			.unwrap()
		};
		assert!(held.same_room(&row("room", "published")));
		assert!(!held.same_room(&row("room", "republished")), "another publication");
		assert!(!held.same_room(&row("copy", "published")), "another room id");
	}
	#[test]
	fn the_entrance_holds_the_room_and_the_seat_holds_an_entranceless_one() {
		let entranced = witness(KEY, Some(OTHER));
		assert_eq!(
			entranced.basis(),
			custody::Coordinate::new(custody::Role::RoomAccess, entranced.access.unwrap())
		);
		let bare = witness(KEY, None);
		assert_eq!(bare.entrance(), None);
		assert_eq!(bare.basis(), bare.seat_coordinate());
	}
}
