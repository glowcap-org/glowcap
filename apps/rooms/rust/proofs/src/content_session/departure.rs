//! Local retirement keeps shared selections, exact generations, independent
//! imports and receipt authority. Validation uses the same selection inventory.
use super::*;
use rooms_application::{content::session::local, session::command::Request};

fn apply(
	intent: &mut workspace::Intent,
	custody: &mut custody::Custody<References>,
	name: &str,
	args: &[&str],
) -> Result<(), local::Refusal> {
	use crate::arguments::Arg;
	let mut wire = vec![Arg::Text("departure".into()), Arg::Integer(1), Arg::Text(name.into())];
	wire.extend(args.iter().map(|s| Arg::Text((*s).into())));
	let request = Request::parse(&wire).unwrap();
	assert!(local::recognizes(request.route()));
	assert!(requirements::command(request.route()).unwrap().targets.is_empty());
	local::apply(&request, intent, custody)
}
fn populate(intent: &workspace::Intent) -> custody::Custody<References> {
	use custody::{Held, Role};
	let mut fields = custody::Custody::<References>::default();
	for coordinate in intent.coordinates() {
		if fields.get(coordinate).is_some() {
			continue;
		}
		let key = coordinate.key;
		macro_rules! held {
			($reference:expr) => {
				Held {
					key: custody::FieldKey::new(key.slot(), key.generation()),
					reference: $reference,
				}
			};
		}
		match coordinate.role {
			Role::SessionAccess => fields.insert_session_access(held!(Source(key.slot().get()))),
			Role::DirectoryName => fields.insert_directory_name(held!(())),
			Role::DirectoryInbox => fields.insert_directory_inbox(held!(())),
			Role::RoomInbox => fields.insert_room_inbox(held!(())),
			Role::DirectInbox => fields.insert_direct_inbox(held!(())),
			Role::RoomAccess => fields.insert_room_access(held!(Room(key.slot().get()))),
			Role::DirectoryAccess => fields.insert_directory_access(held!(Directory)),
			Role::DirectAccess => fields.insert_direct_access(held!(())),
			Role::RoomSeat => fields.insert_room_seat(held!(())),
			Role::RoomSubject => fields.insert_room_subject(held!(())),
			Role::RoomFiles => fields.insert_room_files(held!(())),
			Role::Line => fields.insert_line(held!(())),
			Role::RoomControl => fields.insert_room_control(held!(())),
			Role::Offer => fields.insert_offer(held!(())),
			Role::AcceptedAccess => fields.insert_accepted_access(held!(())),
			Role::PublicationLease => fields.insert_publication_lease(held!(())),
			Role::ArchiveAccess => fields.insert_archive_access(held!(())),
			Role::ArchiveControl => fields.insert_archive_control(held!(())),
			Role::Operator => fields.insert_operator(held!(())),
			Role::Operations => fields.insert_operations(held!(())),
			Role::IrcConnection => fields.insert_irc_connection(held!(())),
			_ => panic!("unexpected intent custody role"),
		}
		.unwrap();
	}
	fields
}
pub fn run() {
	replacement_retires_more_than_one_page_and_preserves_aliases();
	clear_preserves_management_and_erasure();
	let mut raw = fixture();
	raw["directories"][0]["name"] = json!(key::<custody::DirectoryName>(26, 27));
	raw["directories"][0]["source"] = json!(key::<custody::SessionAccess>(28, 29));
	raw["directories"][0]["inbox"] = json!(key::<custody::DirectoryInbox>(30, 31));
	raw["conversations"][0]["inbox"] = json!(key::<custody::RoomInbox>(32, 33));
	let mut second = raw["conversations"][0].clone();
	second["id"] = json!("second");
	second["seat"] = json!(key::<custody::RoomSeat>(2, 3));
	second["inbox"] = json!(key::<custody::RoomInbox>(34, 35));
	second["subject"] = json!(key::<custody::RoomSubject>(4, 5));
	second["files"] = json!(key::<custody::RoomFiles>(24, 25));
	second["moderator"] = json!(key::<custody::RoomAccess>(6, 7));
	second["control"] = json!(key::<custody::RoomControl>(8, 9));
	second["lines"] = json!([{ "id": 23, "handle": key::<custody::Line>(10, 11) }]);
	raw["conversations"].as_array_mut().unwrap().push(second);
	raw["invitations"] = json!([{ "id": "invitation", "directory": "directory", "authority": {"role":"offer", "key":key::<custody::Offer>(12, 13)}, "label": "offer", "from": "peer" }]);
	raw["peering"] = json!([{ "id": "publication", "directory": "directory", "room": key::<custody::RoomAccess>(1, 1), "lease": key::<custody::PublicationLease>(14, 15), "name": "room" }]);
	raw["archive"] = json!(key::<custody::ArchiveAccess>(16, 17));
	raw["archiveControl"] = json!(key::<custody::ArchiveControl>(18, 19));
	raw["operators"] = json!([key::<custody::Operator>(20, 21)]);
	let initial = workspace::Intent::decode(&raw.to_string()).unwrap();
	let mut revoked = initial.clone();
	let workspace::Conversation::Room(room) = &mut revoked.conversations.as_mut_slice()[0] else {
		panic!("room")
	};
	room.source = Some(key(28, 29));
	room.seat = Some(key(2, 3));
	let mut revoked_custody = populate(&revoked);
	let callback = workspace::InboxSelection::room(
		match &revoked.conversations.as_slice()[0] {
			workspace::Conversation::Room(row) => row,
			_ => panic!("room"),
		},
		&revoked,
	)
	.unwrap();
	local::retire_authority(&mut revoked, &mut revoked_custody, key(1, 1));
	let workspace::Conversation::Room(room) = &revoked.conversations.as_slice()[0] else {
		panic!("room")
	};
	assert!(room.access.is_none());
	assert_eq!(room.reconnect, workspace::Reconnect::Manual);
	assert!(
		room.seat.is_some(),
		"entry revocation cannot retire independent membership"
	);
	assert!(room.requests_membership());
	assert!(
		callback.matches(&revoked),
		"the installed callback belongs to the surviving seat"
	);
	for field in ["access", "source", "inbox", "seat"] {
		let mut replaced = serde_json::to_value(&revoked).unwrap();
		replaced["conversations"][0][field] = if field == "seat" {
			json!(null)
		} else {
			json!(key::<custody::RoomAccess>(90, 91))
		};
		let replaced = workspace::Intent::decode(&replaced.to_string()).unwrap();
		assert!(
			!callback.matches(&replaced),
			"retired callback cannot cross {field} replacement"
		);
	}
	assert!(
		revoked_custody.room_access(key(1, 1)).is_some(),
		"independent publication still selects its custody"
	);
	let lease = revoked.peering.as_slice()[0].lease;
	local::retire_publication(&mut revoked, &mut revoked_custody, lease).unwrap();
	assert!(revoked_custody.room_access(key(1, 1)).is_none());
	assert_eq!(revoked.validate(&revoked_custody), Ok(()));
	// Membership retirement clears every exact seat alias, preserving unrelated
	// room authority and shared fields still selected by a different membership.
	let mut retiring = initial.clone();
	let workspace::Conversation::Room(second) = &retiring.conversations.as_slice()[1] else {
		panic!("room");
	};
	let mut alias = second.clone();
	alias.id = rooms_application::fields::Text::new("alias".into()).unwrap();
	retiring
		.conversations
		.try_push(workspace::Conversation::Room(alias))
		.unwrap();
	let workspace::Conversation::Room(first) = &mut retiring.conversations.as_mut_slice()[0] else {
		panic!("room");
	};
	first.subject = Some(key(4, 5));
	first.files = Some(key(24, 25));
	let before = retiring.clone();
	let mut retained = populate(&retiring);
	assert!(local::retire_membership(&mut retiring, &mut retained, key(2, 4)).is_err());
	assert_eq!(retiring, before);
	local::retire_membership(&mut retiring, &mut retained, key(2, 3)).unwrap();
	for row in retiring.conversations.as_slice().iter().skip(1) {
		let workspace::Conversation::Room(room) = row else {
			panic!("room");
		};
		assert!(room.seat.is_none() && room.subject.is_none() && room.files.is_none() && room.lines.is_empty());
		assert_eq!(room.reconnect, workspace::Reconnect::Manual);
		assert_eq!(room.control, Some(key(8, 9)));
	}
	assert!(retained.room_seat(key(2, 3)).is_none());
	assert!(retained.line(key(10, 11)).is_none());
	assert!(retained.room_inbox(key(34, 35)).is_none());
	assert!(retained.room_inbox(key(32, 33)).is_some());
	assert!(
		retained.room_files(key(24, 25)).is_some(),
		"another membership still selects the files facet"
	);
	assert!(
		retained.room_subject(key(4, 5)).is_some(),
		"another membership still selects the subject"
	);
	assert_eq!(retiring.validate(&retained), Ok(()));
	let mut publications = initial.clone();
	let mut alias = publications.peering.as_slice()[0].clone();
	alias.id = rooms_application::fields::Text::new("publication-alias".into()).unwrap();
	publications.peering.try_push(alias).unwrap();
	let mut independent = publications.peering.as_slice()[0].clone();
	independent.id = rooms_application::fields::Text::new("independent-publication".into()).unwrap();
	independent.lease = key(16, 15);
	publications.peering.try_push(independent).unwrap();
	let mut retained = populate(&publications);
	let before = publications.clone();
	assert!(local::retire_publication(&mut publications, &mut retained, key(14, 17)).is_err());
	assert_eq!(publications, before);
	local::retire_publication(&mut publications, &mut retained, key(14, 15)).unwrap();
	assert_eq!(publications.peering.as_slice().len(), 1);
	assert_eq!(publications.peering.as_slice()[0].lease, key(16, 15));
	assert!(retained.publication_lease(key(14, 15)).is_none());
	assert!(retained.publication_lease(key(16, 15)).is_some());
	assert!(
		retained.room_access(key(1, 1)).is_some(),
		"room entry is independently selected"
	);
	assert_eq!(publications.conversations, initial.conversations);
	assert_eq!(publications.validate(&retained), Ok(()));
	let mut fields = populate(&initial);
	assert_eq!(initial.validate(&fields), Ok(()));
	// Every declared field is required by validation, including aliases.
	for coordinate in initial.coordinates() {
		let held = fields.remove(coordinate).unwrap();
		assert_eq!(initial.validate(&fields), Err(workspace::InvalidIntent::Custody));
		fields.insert(held).unwrap();
	}
	fields
		.insert_room_access(custody::Held {
			key: key(30, 31),
			reference: Room(300),
		})
		.unwrap();
	let mut intent = initial.clone();
	apply(&mut intent, &mut fields, "leaveConversation", &["conversation"]).unwrap();
	assert_eq!(intent.active.as_ref().unwrap().text().as_str(), Some("second"));
	assert!(
		fields.room_access(key(1, 1)).is_some(),
		"another row and peering keep the alias"
	);
	assert_eq!(intent.validate(&fields), Ok(()));
	let stale = serde_json::to_string(&key::<custody::RoomAccess>(6, 8)).unwrap();
	let before = fields.len();
	assert!(apply(&mut intent, &mut fields, "dropRoomModerator", &["second", &stale]).is_err());
	assert_eq!(fields.len(), before);
	let expected = serde_json::to_string(&key::<custody::RoomAccess>(6, 7)).unwrap();
	apply(&mut intent, &mut fields, "dropRoomModerator", &["second", &expected]).unwrap();
	assert!(fields.room_access(key(6, 7)).is_none());
	let expected = serde_json::to_string(&key::<custody::RoomControl>(8, 9)).unwrap();
	apply(&mut intent, &mut fields, "dropRoomManager", &["second", &expected]).unwrap();
	assert!(fields.room_control(key(8, 9)).is_none());
	apply(&mut intent, &mut fields, "leaveDirectory", &["directory"]).unwrap();
	assert!(intent.directories.is_empty() && intent.conversations.is_empty());
	assert!(intent.invitations.is_empty() && intent.peering.is_empty() && intent.active.is_none());
	assert!(fields.directory_access(key(1, 1)).is_none());
	assert!(fields.directory_name(key(26, 27)).is_none());
	assert!(fields.session_access(key(28, 29)).is_none());
	assert!(fields.directory_inbox(key(30, 31)).is_none());
	assert!(fields.room_inbox(key(32, 33)).is_none());
	assert!(fields.room_access(key(1, 1)).is_none());
	assert!(fields.room_seat(key(2, 3)).is_none());
	assert!(fields.room_subject(key(4, 5)).is_none());
	assert!(fields.room_files(key(24, 25)).is_none());
	assert!(fields.line(key(10, 11)).is_none());
	assert!(fields.offer(key(12, 13)).is_none());
	assert!(fields.publication_lease(key(14, 15)).is_none());
	assert!(fields.archive_access(key(16, 17)).is_some());
	assert!(fields.archive_control(key(18, 19)).is_some());
	assert!(fields.operator(key(20, 21)).is_some());
	assert!(
		fields.room_access(key(30, 31)).is_some(),
		"unrelated imports remain held"
	);
	assert_eq!(intent.validate(&fields), Ok(()));
	assert!(apply(&mut intent, &mut fields, "leaveDirectory", &["directory"]).is_err());
	// Dropping moderation cannot release the same field used for room entry.
	let mut alias = initial.clone();
	let workspace::Conversation::Room(room) = &mut alias.conversations.as_mut_slice()[0] else {
		panic!("room");
	};
	room.moderator = room.access;
	let mut fields = populate(&alias);
	let expected = serde_json::to_string(&key::<custody::RoomAccess>(1, 1)).unwrap();
	apply(
		&mut alias,
		&mut fields,
		"dropRoomModerator",
		&["conversation", &expected],
	)
	.unwrap();
	assert!(fields.room_access(key(1, 1)).is_some());
	assert_eq!(alias.validate(&fields), Ok(()));
	// A departed directory cannot release aliases selected by another directory.
	let mut raw = raw.clone();
	let mut directory = raw["directories"][0].clone();
	directory["id"] = json!("other-directory");
	directory["home"] = json!(false);
	raw["directories"].as_array_mut().unwrap().push(directory);
	raw["conversations"][1]["directory"] = json!("other-directory");
	raw["conversations"].as_array_mut().unwrap().push(json!({
		"kind": "direct", "id": "direct", "directory": "other-directory", "peer": "peer",
		"access": key::<custody::DirectAccess>(22, 23), "closed": false, "draft": ""
	}));
	raw["conversations"].as_array_mut().unwrap().push(json!({
		"kind": "direct", "id": "closed", "directory": "other-directory", "peer": "peer",
		"access": null, "closed": true, "draft": ""
	}));
	let mut invitation = raw["invitations"][0].clone();
	invitation["id"] = json!("other-invitation");
	invitation["directory"] = json!("other-directory");
	raw["invitations"].as_array_mut().unwrap().push(invitation);
	let mut publication = raw["peering"][0].clone();
	publication["id"] = json!("other-publication");
	publication["directory"] = json!("other-directory");
	raw["peering"].as_array_mut().unwrap().push(publication);
	let mut intent = workspace::Intent::decode(&raw.to_string()).unwrap();
	let mut fields = populate(&intent);
	let direct = fields
		.remove(custody::Coordinate {
			role: custody::Role::DirectAccess,
			key: key(22, 23),
		})
		.unwrap();
	assert_eq!(intent.validate(&fields), Err(workspace::InvalidIntent::Custody));
	fields.insert(direct).unwrap();
	apply(&mut intent, &mut fields, "leaveDirectory", &["directory"]).unwrap();
	assert_eq!(intent.active.as_ref().unwrap().text().as_str(), Some("second"));
	assert!(fields.directory_access(key(1, 1)).is_some());
	assert!(
		fields.directory_name(key(26, 27)).is_some(),
		"another directory keeps the name alias"
	);
	assert!(
		fields.session_access(key(28, 29)).is_some(),
		"another directory keeps its initiating source"
	);
	assert!(fields.offer(key(12, 13)).is_some());
	assert!(fields.publication_lease(key(14, 15)).is_some());
	assert_eq!(intent.validate(&fields), Ok(()));
	apply(&mut intent, &mut fields, "leaveConversation", &["second"]).unwrap();
	assert_eq!(intent.active.as_ref().unwrap().text().as_str(), Some("direct"));
	apply(&mut intent, &mut fields, "leaveConversation", &["direct"]).unwrap();
	assert!(intent.active.is_none(), "a closed direct is not a fallback selection");
	assert!(fields.direct_access(key(22, 23)).is_none());
	assert_eq!(intent.validate(&fields), Ok(()));
}

fn replacement_retires_more_than_one_page_and_preserves_aliases() {
	let mut raw = fixture();
	raw["operators"] = json!(
		(1..=64)
			.map(|slot| key::<custody::Operator>(slot, 1))
			.collect::<Vec<_>>()
	);
	raw["operations"] = json!((1..=64).map(|slot| json!({ "kind": "listeners", "handle": { "role": "operations", "key": key::<custody::Operations>(slot, 1) } })).collect::<Vec<_>>());
	let mut intent = workspace::Intent::decode(&raw.to_string()).unwrap();
	let mut fields = populate(&intent);
	fields
		.insert_room_access(custody::Held {
			key: key(900, 1),
			reference: Room(900),
		})
		.unwrap();
	let mut candidate = raw.clone();
	candidate["operators"] = json!([key::<custody::Operator>(1, 1)]);
	candidate["operations"] = json!([]);
	candidate["conversations"][0]
		.as_object_mut()
		.unwrap()
		.remove("moderator");
	// This entrance is also selected as moderation. Removing moderation must
	// leave the exact entrance occurrence in custody.
	if let workspace::Conversation::Room(room) = &mut intent.conversations.as_mut_slice()[0] {
		room.moderator = room.access;
	}
	let candidate = workspace::Intent::decode(&candidate.to_string()).unwrap();
	intent.replace_configuration_retiring(candidate, &mut fields).unwrap();
	assert!(fields.operator(key(1, 1)).is_some());
	for slot in 2..=64 {
		assert!(fields.operator(key(slot, 1)).is_none());
	}
	for slot in 1..=64 {
		assert!(fields.operations(key(slot, 1)).is_none());
	}
	assert!(fields.room_access(key(1, 1)).is_some());
	assert!(
		fields.room_access(key(900, 1)).is_some(),
		"independent imported custody survives replacement"
	);
	let before = serde_json::to_string(&intent).unwrap();
	let count = fields.len();
	let mut invalid = raw;
	invalid["keepHistory"] = json!(!intent.keep_history);
	assert!(
		intent
			.replace_configuration_retiring(workspace::Intent::decode(&invalid.to_string()).unwrap(), &mut fields)
			.is_err()
	);
	assert_eq!(serde_json::to_string(&intent).unwrap(), before);
	assert_eq!(fields.len(), count);
}

fn clear_preserves_management_and_erasure() {
	use custody::{Held, Role};
	let mut raw = fixture();
	raw["historyErasure"] = json!("pending-erasure");
	raw["keepHistory"] = json!(false);
	raw["accesses"] =
		json!([{ "id": "management", "access": null, "control": key::<custody::SessionControl>(900, 901) }]);
	raw["conversations"][0]["lines"] = json!(
		(1..=100)
			.map(|id| json!({"id":id,"handle":key::<custody::Line>(1000 + id, 1)}))
			.collect::<Vec<_>>()
	);
	let mut intent = workspace::Intent::decode(&raw.to_string()).unwrap();
	// Populate the content topology separately from the independently saved
	// control because the fixture's reference algebra uses distinct role types.
	let accesses = core::mem::take(&mut intent.accesses);
	let mut fields = populate(&intent);
	intent.accesses = accesses;
	fields
		.insert_session_control(Held {
			key: key(900, 901),
			reference: (),
		})
		.unwrap();
	let receipt_source = custody::Coordinate {
		role: Role::SessionAccess,
		key: key(999, 1),
	};
	fields
		.insert_session_access(Held {
			key: key(999, 1),
			reference: Source(999),
		})
		.unwrap();
	assert!(intent.coordinates().count() > rooms_application::content::session::records::FIELDS_PER_PAGE);
	assert_eq!(intent.validate(&fields), Ok(()));
	apply(&mut intent, &mut fields, "clearWorkspace", &[]).unwrap();
	assert!(intent.conversations.as_slice().is_empty());
	assert!(intent.directories.as_slice().is_empty());
	assert_eq!(intent.accesses.as_slice().len(), 1);
	assert_eq!(
		intent.history_erasure.as_ref().unwrap().text().as_str(),
		Some("pending-erasure")
	);
	assert!(fields.session_control(key(900, 901)).is_some());
	assert!(
		fields.get(receipt_source).is_some(),
		"an admitted effect keeps its independent source occurrence"
	);
	assert!(fields.line(key(1001, 1)).is_none());
	assert_eq!(intent.validate(&fields), Ok(()));
}
