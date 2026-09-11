//! The authority read from the TypeScript owner's document, its derivations
//! pinned to vectors captured from that owner, and every change as a value.
use super::*;
use crate::server::document::Document;
use alloc::vec::Vec;

/// The document the TypeScript owner writes for a server with one linked
/// room, a steward, a manager, and a managed room under it; the derivation
/// vectors below were captured from the historical TypeScript owner over this document.
const KEPT: &str = r#"{"version":1,"identitySeed":"0101010101010101010101010101010101010101010101010101010101010101","roomLinkSecret":"0202020202020202020202020202020202020202020202020202020202020202","linkedRooms":["Garden","~00000000000000000000000000000001"],"revokedRooms":["old"],"roomLinkGenerations":[{"name":"garden","generation":3}],"stewards":[{"name":"garden","generation":1,"issued":true}],"managers":[{"name":"~00000000000000000000000000000001","generation":2,"issued":false},{"name":"old","generation":1,"issued":true}],"managedRooms":[{"id":"~00000000000000000000000000000001","name":"Garden","generation":2,"policy":{"visibility":"listed","entry":"open","speaking":"moderated"}}],"topics":[{"name":"garden","topic":"seedlings"},{"name":"~00000000000000000000000000000001","topic":"kept"}]}"#;
const MANAGED: &str = "~00000000000000000000000000000001";

fn kept() -> Authority {
	Authority::read(&Document::decode(KEPT).unwrap()).unwrap()
}

fn hex(bytes: &[u8]) -> String {
	super::hex(bytes)
}

#[test]
fn the_kept_document_reads_and_writes_back_the_same_relations() {
	let authority = kept();
	assert_eq!(authority.linked_rooms().collect::<Vec<_>>(), ["Garden", MANAGED]);
	assert!(authority.room_link_active("garden"));
	assert_eq!(authority.room_link_generation("GARDEN"), 3);
	assert!(authority.room_link_generation_is_current("Garden", 3));
	assert!(!authority.room_link_generation_is_current("old", 0));
	assert!(authority.has_steward("Garden"));
	assert_eq!(authority.steward_generation("garden"), 1);
	assert!(!authority.has_manager(MANAGED));
	assert_eq!(authority.manager_generation(MANAGED), 2);
	assert!(authority.has_manager("old"));
	assert_eq!(authority.managed_room(MANAGED).unwrap().name, "Garden");
	assert_eq!(authority.managed_room_id_for_name("garden"), Some(MANAGED));
	assert!(authority.managed_room_generation_is_current(MANAGED, 2));
	assert_eq!(authority.topic("Garden"), Some("seedlings"));
	assert_eq!(authority.topic(MANAGED), Some("kept"));
	// The document written back holds the same relations; row order and the
	// casing a generation row remembers are the writer's, not the contract.
	let written = authority.document();
	assert_eq!(Authority::read(&written).unwrap(), authority);
	assert_eq!(
		Authority::read(&Document::decode(&written.encode().unwrap()).unwrap()).unwrap(),
		authority
	);
}

#[test]
fn derivations_match_the_typescript_owner() {
	let authority = kept();
	assert_eq!(
		hex(&authority.room_entropy("Garden", 3)),
		"401d42f644b5416e765153547ff1cc99"
	);
	assert_eq!(
		hex(&authority.room_entropy("Garden", 0)),
		"69a6defe9d4b6c06982cf08633e6a354"
	);
	assert_eq!(
		hex(&authority.room_entropy(MANAGED, 0)),
		"fa2a65a38c2475598cda13438d2af660"
	);
	assert_eq!(
		hex(&authority.steward_entropy("Garden", 1)),
		"6ec3559075cc70aa2e73a2c06620a686"
	);
	assert_eq!(
		hex(&authority.steward_entropy("Garden", 0)),
		"1a4f7ba21cf7c86898857d4bcc4b6d4a"
	);
	assert_eq!(
		hex(&authority.steward_entropy("old", 0)),
		"f31215cd40a877e249545686f4bb6950"
	);
	assert_eq!(
		hex(&authority.manager_entropy(MANAGED, 2)),
		"ee7a888664843beeb4155f498f13182e"
	);
	assert_eq!(
		hex(&authority.manager_entropy("old", 1)),
		"bff98fb2dd63a34474d21bea83b7e173"
	);
	assert_eq!(authority.manager_identity("Garden"), "4ad15b7a15e95c4552983881f3146993");
	assert_eq!(authority.manager_identity(MANAGED), "370e11f508b513a822aa4a34bf965791");
	assert_eq!(
		crate::room::authority::room_identity("abc").unwrap(),
		"f973c89fd448e068d6cbeb9cf64da077e622dce8fd983733725aa2f56c7cbfd4"
	);
}

#[test]
fn remembering_links_a_name_once_and_revives_a_revoked_one_under_a_new_generation() {
	let authority = kept();
	assert_eq!(authority.remembered("garden", false, false, None, None).unwrap(), None);
	let next = authority
		.remembered("Orchard", false, false, Some("apples"), None)
		.unwrap()
		.unwrap();
	assert!(next.room_link_active("orchard"));
	assert_eq!(next.room_link_generation("Orchard"), 0);
	assert_eq!(next.topic("orchard"), Some("apples"));
	assert_eq!(next.document().linked_rooms.as_slice().len(), 3);
	// A topic is remembered only when the room has none.
	let same = next.remembered("Orchard", false, false, Some("pears"), None).unwrap();
	assert_eq!(same, None);
	// A revoked name comes back under the next generation.
	let revived = next.remembered("old", false, false, None, None).unwrap().unwrap();
	assert!(revived.room_link_active("old"));
	assert_eq!(revived.room_link_generation("old"), 1);
	assert!(revived.document().revoked_rooms.as_slice().is_empty());
	assert_ne!(revived.room_entropy("old", 1), authority.room_entropy("old", 0));
}

#[test]
fn stewards_and_managers_issue_by_generation_and_revoke_to_the_next() {
	let authority = kept();
	let (revoked, generation) = authority.with_steward_revoked("Garden").unwrap();
	assert_eq!(generation, 2);
	assert!(!revoked.has_steward("garden"));
	assert!(revoked
		.stewardship("garden")
		.is_some_and(|row| row.generation == 2 && !row.issued));
	assert_eq!(
		revoked.with_steward_revoked("Garden").unwrap_err().code,
		Some(FailureCode::NotSteward)
	);
	let reissued = revoked.remembered("Garden", true, false, None, None).unwrap().unwrap();
	assert!(reissued.steward_generation_is_current("Garden", 3));
	assert_ne!(
		reissued.steward_entropy("Garden", 3),
		authority.steward_entropy("Garden", 1)
	);
	let (managers, generation) = authority.with_manager_revoked("old").unwrap();
	assert_eq!(generation, 2);
	assert!(!managers.has_manager("old"));
	assert_eq!(managers.with_manager_revoked("old").unwrap_err().code, None);
	let reissued = managers.remembered(MANAGED, false, true, None, None).unwrap().unwrap();
	assert!(reissued.manager_generation_is_current(MANAGED, 3));
}

#[test]
fn a_managed_room_is_filed_under_its_opaque_id_and_repolicied_by_generation() {
	let authority = kept();
	let id = "~00000000000000000000000000000002";
	let refused = authority
		.remembered(
			"Plain",
			false,
			true,
			None,
			Some(Registration {
				name: "Plain",
				policy: RoomPolicy::Open,
			}),
		)
		.unwrap_err();
	assert_eq!(refused.reason(), "managed room state needs opaque room identity");
	let next = authority
		.remembered(
			id,
			false,
			true,
			Some("hi"),
			Some(Registration {
				name: "Yard",
				policy: RoomPolicy::Private,
			}),
		)
		.unwrap()
		.unwrap();
	assert!(next.has_manager(id));
	assert_eq!(next.managed_room(id).unwrap().generation, 1);
	assert_eq!(
		next.managed_room_id_for_name("Yard"),
		None,
		"a private room is not named"
	);
	let listed = next
		.with_managed_room_policy(id, "Yard", RoomPolicy::Open)
		.unwrap()
		.unwrap();
	assert_eq!(listed.managed_room_id_for_name("yard"), Some(id));
	assert_eq!(listed.managed_room(id).unwrap().generation, 2);
	assert_eq!(
		listed.with_managed_room_policy(id, "Yard", RoomPolicy::Open).unwrap(),
		None
	);
	// A different registration cannot overwrite a filed managed room.
	let refused = listed
		.remembered(
			id,
			false,
			false,
			None,
			Some(Registration {
				name: "Other",
				policy: RoomPolicy::Open,
			}),
		)
		.unwrap_err();
	assert_eq!(
		refused.reason(),
		"managed room creation does not replace existing room state"
	);
	Authority::read(&listed.document()).unwrap();
}

#[test]
fn topics_follow_durable_names_and_a_link_revocation() {
	let authority = kept();
	assert_eq!(authority.with_topic("Garden", "seedlings").unwrap(), None);
	let changed = authority.with_topic("garden", "sprouts").unwrap().unwrap();
	assert_eq!(changed.topic("Garden"), Some("sprouts"));
	let cleared = changed.with_topic("Garden", "").unwrap().unwrap();
	assert_eq!(cleared.topic("Garden"), None);
	// An unlinked managed id keeps no topic; an unlinked public name does.
	assert_eq!(
		cleared.with_topic("~00000000000000000000000000000009", "x").unwrap(),
		None
	);
	let public = cleared.with_topic("Meadow", "grass").unwrap().unwrap();
	assert_eq!(public.topic("meadow"), Some("grass"));
	Authority::read(&public.document()).unwrap();
	let long = "x".repeat(document::MAX_TOPIC + 1);
	assert!(public.with_topic("Garden", &long).is_err());
	// A managed room still filed under its manager cannot lose its link: the
	// document's relations refuse it, as the TypeScript owner's write does.
	let refused = authority.with_room_link_revoked(MANAGED).unwrap_err();
	assert!(
		refused.reason().starts_with("rooms state change is invalid"),
		"{refused}"
	);
	// A public room's link goes with its steward; its topic stays.
	let revoked = authority.with_room_link_revoked("Garden").unwrap();
	assert!(!revoked.room_link_active("garden"));
	assert!(!revoked.has_steward("Garden"));
	assert_eq!(revoked.topic("Garden"), Some("seedlings"));
	assert_eq!(revoked.document().revoked_rooms.as_slice().len(), 2);
	assert_eq!(
		revoked.with_room_link_revoked("nowhere").unwrap_err().code,
		Some(FailureCode::NoSuchRoom)
	);
	Authority::read(&revoked.document()).unwrap();
}

#[test]
fn a_factory_reset_keeps_identity_and_public_topics_only() {
	let authority = kept();
	let reset = authority.factory_reset([9; KEY_BYTES]);
	assert_eq!(reset.identity_seed(), authority.identity_seed());
	assert_eq!(reset.linked_rooms().count(), 0);
	assert!(!reset.has_steward("Garden"));
	assert_eq!(reset.topic("Garden"), Some("seedlings"));
	assert_eq!(reset.topic(MANAGED), None);
	assert_ne!(reset.room_entropy("Garden", 0), authority.room_entropy("Garden", 0));
	Authority::read(&reset.document()).unwrap();
}

#[test]
fn the_link_registry_is_bounded() {
	let mut full = Document::fresh([1; KEY_BYTES], [2; KEY_BYTES]);
	full.linked_rooms = List(
		(0..document::MAX_ROOM_LINKS - 1)
			.map(|n| durable(&format!("r{n}")))
			.collect(),
	);
	full.revoked_rooms = List(alloc::vec![durable("gone")]);
	let authority = Authority::read(&full).unwrap();
	let refused = authority.remembered("one-more", false, false, None, None).unwrap_err();
	assert_eq!(refused.code, Some(FailureCode::RoomLinksFull));
	assert!(authority.remembered("r1", false, false, None, None).unwrap().is_none());
	// A revoked name comes back without spending a row.
	assert!(authority
		.remembered("gone", false, false, None, None)
		.unwrap()
		.is_some());
}
