use rooms_application::{
	grants::Access,
	session::{
		checkpoint::{
			Checkpoint, Routes,
			commands::CommandRoutes,
			reconciliation::{Authority, Fact, RoomContext, Text},
		},
		state::Impact,
	},
};
use serde_json::{Value, value::RawValue};
use std::collections::BTreeMap;
struct CapturedRoutes<'a>(&'a Value);
impl Routes for CapturedRoutes<'_> {
	fn locator_authority(&self, raw: &str) -> Option<String> {
		self.0["locatorAuthorities"][raw].as_str().map(str::to_owned)
	}
	fn sturdyref_authority(&self, raw: &str) -> Option<String> {
		self.0["sturdyrefAuthorities"][raw].as_str().map(str::to_owned)
	}
}
impl CommandRoutes for CapturedRoutes<'_> {
	fn authority_token(&self, raw: &str) -> Option<String> {
		self.0["tokens"][raw].as_str().map(str::to_owned)
	}
}
fn fact(raw: &str, current: &Checkpoint) -> Fact {
	let fields: BTreeMap<String, Box<RawValue>> = serde_json::from_str(raw).unwrap();
	fn field<const N: usize, const NONEMPTY: bool>(
		fields: &BTreeMap<String, Box<RawValue>>,
		key: &str,
	) -> Text<N, NONEMPTY> {
		serde_json::from_str(fields[key].get()).unwrap()
	}
	// These fixtures describe delayed effects, so capture their originating
	// checkpoint here. Delayed-fact scenarios retain this context across edits.
	let context = || {
		let id: String = serde_json::from_str(fields["conversationId"].get()).unwrap();
		RoomContext::capture(
			current
				.rooms()
				.find(|room| room.id.text().as_str() == Some(&id))
				.or_else(|| current.rooms().next())
				.expect("room fixture context"),
		)
	};
	let tag: String = serde_json::from_str(fields["type"].get()).unwrap();
	match tag.as_str() {
		"directory-reached" => Fact::DirectoryReached {
			directory: field(&fields, "directoryId"),
			locator: field(&fields, "locator"),
		},
		"room-reconnect" => Fact::RoomReconnect {
			context: context(),
			conversation: field(&fields, "conversationId"),
			connected: serde_json::from_str(fields["connected"].get()).unwrap(),
		},
		"room-authority" => {
			let kind: String = serde_json::from_str(fields["kind"].get()).unwrap();
			Fact::RoomAuthority {
				context: context(),
				conversation: field(&fields, "conversationId"),
				token: field(&fields, "token"),
				claimable: serde_json::from_str(fields["claimable"].get()).unwrap(),
				kind: match kind.as_str() {
					"room" => Authority::Room,
					"manager" => Authority::Manager,
					"steward" => Authority::Steward,
					_ => panic!("fixture kind"),
				},
			}
		}
		"room-authority-acquired" => Fact::RoomAuthorityAcquired {
			context: context(),
			conversation: field(&fields, "conversationId"),
			room_link: field(&fields, "roomLink"),
			manager_link: field(&fields, "managerLink"),
		},
		"room-publication" => Fact::RoomPublication {
			context: context(),
			conversation: field(&fields, "conversationId"),
			publication: field(&fields, "publicationId"),
			expected: if fields["expectedPublicationId"].get() == "null" {
				None
			} else {
				Some(field(&fields, "expectedPublicationId"))
			},
		},
		"direct-accepted" => Fact::DirectAccepted {
			conversation: field(&fields, "conversationId"),
			directory: field(&fields, "directoryId"),
			peer: field(&fields, "peer"),
			registration: field(&fields, "peerRegistrationId"),
		},
		_ => panic!("fixture fact"),
	}
}
fn fixture() -> Value {
	serde_json::from_str(include_str!("../fixtures/reconciliation.json")).unwrap()
}
fn check(fixture: &Value, routes: &impl CommandRoutes) {
	for row in fixture["rows"].as_array().unwrap() {
		let current = Checkpoint::decode(row["before"].as_str().unwrap(), routes).unwrap();
		let before = current.encode_for(Access::Admin).unwrap();
		let fact = fact(row["fact"].as_str().unwrap(), &current);
		let result = fact.apply(&current, routes);
		assert_eq!(
			result.is_ok(),
			row["accepted"].as_bool().unwrap(),
			"{}: {:?}",
			row["name"],
			result.as_ref().err()
		);
		if let Ok(result) = result {
			assert_eq!(result.is_some(), row["after"].is_string(), "{} changed", row["name"]);
			if let Some(after) = result {
				if let Fact::DirectAccepted {
					conversation,
					directory,
					peer,
					registration,
				} = &fact
				{
					let intent = after.directs().find(|intent| intent.id == conversation).unwrap();
					assert_eq!(intent.directory, directory);
					assert_eq!(intent.peer, peer);
					assert_eq!(intent.registration, registration);
					assert!(!intent.closed);
				}
				assert_eq!(
					after.encode_for(Access::Admin).unwrap(),
					row["after"].as_str().unwrap(),
					"{} checkpoint",
					row["name"]
				);
				assert!(
					fact.apply(&after, routes).unwrap().is_none(),
					"{} duplicate",
					row["name"]
				);
			}
		}
		assert_eq!(
			current.encode_for(Access::Admin).unwrap(),
			before,
			"fact mutated its source"
		);
		assert_eq!(
			fact.impact(),
			match row["impact"].as_str().unwrap() {
				"presentation" => Impact::Presentation,
				"realization" => Impact::Realization,
				_ => panic!("fixture impact"),
			}
		);
	}
}
pub fn run() {
	let fixture = fixture();
	check(&fixture, &CapturedRoutes(&fixture));
	stale_room_observations(&fixture, &CapturedRoutes(&fixture));
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[test]
fn reconciliation_uses_actual_routes_and_capability_generations() {
	check(&fixture(), &rooms_glowcap::routes::CheckpointRoutes);
	stale_room_observations(&fixture(), &rooms_glowcap::routes::CheckpointRoutes);
}

fn stale_room_observations(fixture: &Value, routes: &impl CommandRoutes) {
	for name in [
		"acquire-both",
		"publication-first",
		"reconnect-true-requested",
		"retire-manager-true",
	] {
		let row = fixture["rows"]
			.as_array()
			.unwrap()
			.iter()
			.find(|row| row["name"] == name)
			.unwrap();
		let raw = row["before"].as_str().unwrap();
		let before = Checkpoint::decode(raw, routes).unwrap();
		let observed = fact(row["fact"].as_str().unwrap(), &before);
		assert!(observed.apply(&before, routes).unwrap().is_some(), "{name}: baseline");
		for (field, value) in [("name", "replacement"), ("draft", "still typing")] {
			let mut document: Value = serde_json::from_str(raw).unwrap();
			document["conversations"][0][field] = value.into();
			let replacement = Checkpoint::decode(&document.to_string(), routes).unwrap();
			assert_eq!(
				observed.apply(&replacement, routes).unwrap().is_some(),
				field == "draft",
				"{name}: {field}"
			);
		}
	}
}
