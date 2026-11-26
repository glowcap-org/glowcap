//! A room result belongs to the room row its original request named.
use super::*;
use rooms_application::content::session::recovery::Witness;

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
			// A recovered manager lands only in the room its worker was
			// admitted for, held by the entrance or, with none, the seat.
			(custody::Role::RoomControl, [_, _, route, _, witness]) if text(route)? == "recoverRoomManager" => {
				return self.manager_origin(record, receipt, candidate, text(witness)?, selection.destination);
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
impl Request<'_> {
	/// The admitted room's witness decides the whole check. The operator was
	/// checked at admission and may since have been dropped. The seat may be
	/// lost or replaced when an entrance carries the room, and no seat is read.
	fn manager_origin<'r>(
		&self,
		record: &'r MetadataRecord,
		receipt: &'r custody::EffectReceipt<records::Metadata>,
		candidate: &workspace::Intent,
		witness: &str,
		destination: Coordinate,
	) -> Result<Option<OriginTargets<'r>>> {
		let witness = Witness::parse(witness).map_err(|_| refuse("invalid original manager recovery room"))?;
		let id = witness
			.id
			.text()
			.as_str()
			.ok_or_else(|| refuse("invalid original manager recovery room"))?;
		let current = record
			.intent
			.room(id)
			.ok_or_else(|| refuse("original room was removed"))?;
		let next = candidate
			.room(id)
			.ok_or_else(|| refuse("room result must retain its original room"))?;
		let entrance = witness.entrance().is_some();
		for row in [current, next] {
			if !witness.same_room(row) {
				return Err(refuse(REPLACED));
			}
			if !entrance && row.seat != Some(witness.seat) {
				return Err(refuse(
					"the room's seat was lost or replaced and no entrance holds the room",
				));
			}
		}
		if current.control.is_some() {
			return Err(refuse("room already has a manager"));
		}
		let holds = next.control.is_some_and(|key| {
			key.slot() == destination.key.slot() && key.generation() == destination.key.generation()
		});
		if !holds {
			return Err(refuse("room result is not saved into the room its request named"));
		}
		if candidate.coordinates().filter(|held| *held == destination).count() != 1 {
			return Err(refuse("room result is held by another room"));
		}
		let basis = witness.basis();
		let original = receipt
			.targets
			.as_slice()
			.iter()
			.map(|target| target.borrowed())
			.find(|target| target.coordinate() == basis)
			.ok_or_else(|| refuse("room receipt has no original room basis"))?;
		held_at(record, original, "original room basis custody is absent").map(Some)
	}
}

#[cfg(test)]
mod tests {
	//! `room_origin` decides which route may land a manager result. A receipt
	//! an older Rooms wrote for the retired `operator`/`giveManager` request is
	//! built here from its own canonical intent. The fixture is descriptive
	//! (locations and keys), so it holds no live authority.
	use super::*;
	use custody::{FieldKey, Held, RetainedField, Role};
	use rooms_application::fields::{List, Text};
	use std::num::NonZeroU64;

	const GENERATION: u64 = 3;
	const IDENTITY: &str = "manager-identity";

	fn key<K>(slot: u64) -> FieldKey<K> {
		FieldKey::new(NonZeroU64::new(slot).unwrap(), NonZeroU64::new(GENERATION).unwrap())
	}
	fn coordinate(role: Role, slot: u64) -> Coordinate {
		Coordinate::new(role, key::<()>(slot))
	}
	fn at(page: usize, field: usize) -> records::Location {
		records::Location { page, field }
	}
	fn intent(control: Option<Coordinate>) -> workspace::Intent {
		let rows = serde_json::json!({
			"directories": [{
				"id": "directory", "access": coordinate(Role::DirectoryAccess, 1).key, "home": true,
				"nick": "peer", "nickAllocation": "exact", "standing": null
			}],
			"conversations": [{
				"kind": "room", "id": "room", "directory": "directory", "name": "room",
				"access": coordinate(Role::RoomAccess, 1).key, "seat": coordinate(Role::RoomSeat, 1).key,
				"control": control.map(|held| held.key),
				"reconnect": "requested", "standing": null, "draft": ""
			}],
			"operators": [coordinate(Role::Operator, 1).key],
		});
		let mut json = serde_json::to_value(workspace::Intent::empty()).unwrap();
		for (field, value) in rows.as_object().unwrap() {
			json[field] = value.clone();
		}
		workspace::Intent::decode(&json.to_string()).unwrap()
	}
	/// The record the receipt's operator, seat and entrance live in.
	fn record() -> MetadataRecord {
		let mut held = custody::Custody::<records::Metadata>::default();
		let located = |role, slot, field| (coordinate(role, slot), at(1, field));
		for (coordinate, location) in [
			located(Role::Operator, 1, 1),
			located(Role::RoomSeat, 1, 2),
			located(Role::RoomAccess, 1, 3),
			located(Role::DirectoryAccess, 1, 4),
		] {
			match coordinate.role {
				Role::Operator => held.insert_operator(Held {
					key: coordinate.key.retag(),
					reference: location,
				}),
				Role::RoomSeat => held.insert_room_seat(Held {
					key: coordinate.key.retag(),
					reference: location,
				}),
				Role::RoomAccess => held.insert_room_access(Held {
					key: coordinate.key.retag(),
					reference: location,
				}),
				_ => held.insert_directory_access(Held {
					key: coordinate.key.retag(),
					reference: location,
				}),
			}
			.unwrap();
		}
		workspace::Record {
			binding: custody::ResourceBinding {
				resource: loam::BoundResource {
					id: loam::ResourceId {
						owner: [7; 16],
						slot: 1,
						generation: GENERATION,
					},
					kind: 1,
					object: [0; 33],
					revision: 1,
				},
			},
			intent: intent(None),
			fence: Default::default(),
			custody: held,
			outgoing: List::default(),
			bridges: Default::default(),
			effects: List::default(),
		}
	}
	fn receipt(
		canonical: &str,
		targets: Vec<RetainedField<records::Metadata>>,
	) -> custody::EffectReceipt<records::Metadata> {
		custody::EffectReceipt {
			operation: Text::new("recovery".into()).unwrap(),
			disposition: custody::Disposition::Held,
			outgoing: None,
			introduction: None,
			canonical_intent: Text::new(canonical.into()).unwrap(),
			resource_generation: NonZeroU64::new(GENERATION).unwrap(),
			source: Held {
				key: key(1),
				reference: at(1, 0),
			},
			targets: List::new(targets).unwrap(),
			outcome: custody::Outcome::Committed {
				result: Text::new(result_json().into()).unwrap(),
				retained: List::new(vec![RetainedField::RoomControl(Held {
					key: key(1),
					reference: at(2, 0),
				})])
				.unwrap(),
			},
		}
	}
	/// The operator argument a command carries: its serialized field key.
	fn operator_key() -> String {
		serde_json::to_string(&coordinate(Role::Operator, 1).key).unwrap()
	}
	/// The retained result's own key, as the receipt's result data names it.
	fn result_json() -> String {
		serde_json::json!({"control": coordinate(Role::RoomControl, 1).key}).to_string()
	}
	fn operator_target() -> RetainedField<records::Metadata> {
		RetainedField::Operator(Held {
			key: key(1),
			reference: at(1, 1),
		})
	}
	/// The acquisition the browser submits for a manager result: the actual
	/// revision, one RoomControl mapping, no releases, the candidate and no
	/// worker source.
	fn arguments(canonical: &str, candidate: &workspace::Intent) -> [Argument; 7] {
		let coordinates = |slot| serde_json::to_string(&coordinate(Role::RoomControl, slot)).unwrap();
		[
			"recovery".into(),
			canonical.into(),
			Argument::Integer(1),
			Argument::List(vec![Argument::List(vec![coordinates(1).into(), coordinates(9).into()])]),
			Argument::List(Vec::new()),
			serde_json::to_string(candidate).unwrap().into(),
			Argument::Void,
		]
	}
	/// What a refusal must leave as it found it.
	fn snapshot(
		record: &MetadataRecord,
		receipt: &custody::EffectReceipt<records::Metadata>,
		candidate: &workspace::Intent,
	) -> String {
		format!(
			"{}|{}|{}|{}",
			serde_json::to_string(&record.intent).unwrap(),
			receipt.canonical_intent.text().as_str().unwrap(),
			receipt.targets.as_slice().len(),
			serde_json::to_string(candidate).unwrap()
		)
	}

	#[test]
	fn a_manager_result_lands_by_its_recovery_route_and_never_by_the_retired_operator_request() {
		let record = record();
		let candidate = intent(Some(coordinate(Role::RoomControl, 9)));
		// The neighbor: a recovery receipt in the current format reaches the
		// same validator and is accepted with its entrance as the room basis.
		let witness = serde_json::json!({
			"id": "room", "directory": "directory",
			"seat": coordinate(Role::RoomSeat, 1).key, "access": coordinate(Role::RoomAccess, 1).key
		});
		let current_format = serde_json::to_string(&(
			"recovery",
			1u64,
			"recoverRoomManager",
			[operator_key(), witness.to_string()],
		))
		.unwrap();
		let current_receipt = receipt(
			&current_format,
			vec![
				operator_target(),
				RetainedField::RoomSeat(Held {
					key: key(1),
					reference: at(1, 2),
				}),
				RetainedField::RoomAccess(Held {
					key: key(1),
					reference: at(1, 3),
				}),
			],
		);
		let args = arguments(&current_format, &candidate);
		let request = Request::parse("acquire-result-workspace", &args).unwrap();
		let [original, held] = request
			.room_origin(&record, &current_receipt, &candidate)
			.unwrap()
			.expect("a recovery receipt in the current format is checked");
		assert!(
			records::location(&original) == at(1, 3) && records::location(&held) == at(1, 3),
			"the entrance holds the room"
		);

		// The retired request: the generic operator route with the identity, as
		// an older Rooms wrote it. Its result must not land in RoomControl.
		let retired = serde_json::to_string(&(
			"recovery",
			1u64,
			"operator",
			[operator_key().as_str(), "giveManager", IDENTITY],
		))
		.unwrap();
		let retired_receipt = receipt(&retired, vec![operator_target()]);
		let args = arguments(&retired, &candidate);
		let request = Request::parse("acquire-result-workspace", &args).unwrap();
		let before = snapshot(&record, &retired_receipt, &candidate);
		let refused = request
			.room_origin(&record, &retired_receipt, &candidate)
			.err()
			.expect("a retired manager receipt landed");
		assert!(
			format!("{refused:?}").contains("room result differs from its original request"),
			"{refused:?}"
		);
		assert_eq!(
			snapshot(&record, &retired_receipt, &candidate),
			before,
			"a refusal changed its inputs"
		);
	}
}
