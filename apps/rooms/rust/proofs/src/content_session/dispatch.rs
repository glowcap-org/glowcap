//! Command declarations select an exact role and generation without authority.
use super::*;
use rooms_application::{content::session::dispatch::Dispatch, session::command::Request};

fn dispatch(name: &str, args: &[&str]) -> Result<Dispatch, rooms_application::content::session::dispatch::Refusal> {
	use crate::arguments::Arg;
	let mut wire = vec![Arg::Text("effect".into()), Arg::Integer(1), Arg::Text(name.into())];
	wire.extend(args.iter().map(|s| Arg::Text((*s).into())));
	Dispatch::parse(&Request::parse(&wire).unwrap())
}

pub fn run() {
	let mut raw = fixture();
	raw["conversations"][0]["inbox"] = json!(key::<custody::RoomInbox>(12, 13));
	raw["conversations"][0]["control"] = json!(key::<custody::RoomControl>(2, 3));
	raw["conversations"][0]["moderator"] = json!(key::<custody::RoomAccess>(4, 5));
	raw["conversations"][0]["seat"] = json!(key::<custody::RoomSeat>(6, 7));
	raw["conversations"][0]["subject"] = json!(key::<custody::RoomSubject>(8, 9));
	raw["conversations"][0]["lines"] = json!([{ "id": 23, "handle": key::<custody::Line>(10, 11) }]);
	raw["peering"] = json!([{ "id": "publication", "directory": "directory", "room": key::<custody::RoomAccess>(1, 1), "lease": key::<custody::PublicationLease>(14, 15), "name": "room" }]);
	raw["operations"] =
		json!([{ "kind":"peering", "handle": {"role":"operations", "key":key::<custody::Operations>(30,31)} }]);
	let intent = workspace::Intent::decode(&raw.to_string()).unwrap();
	let registration = "00000000-0000-4000-8000-000000000001";
	let direct = dispatch("startDirect", &["directory", "peer", registration, "opening"]).unwrap();
	assert_eq!(direct.target(&intent).unwrap().role, custody::Role::DirectoryAccess);
	assert_eq!(direct.mutation.verb, "introduce");
	assert_eq!(direct.mutation.args, ["peer", registration, "opening"]);
	assert!(direct.target(&workspace::Intent::empty()).is_err());
	for invalid in [
		&["directory", "peer"][..],
		&["directory", "bad\nnick", registration][..],
		&["directory", "peer", "stale-registration"][..],
	] {
		assert!(dispatch("startDirect", invalid).is_err());
	}
	let receipt = "00112233445566778899aabbccddeeff";
	let mut invited = raw.clone();
	invited["invitations"] = json!([{ "id": "invitation", "directory": "directory", "authority":{"role":"offer", "key":key::<custody::Offer>(20, 21)}, "label": "room", "from": "peer" }]);
	let invited = workspace::Intent::decode(&invited.to_string()).unwrap();
	let accepted = dispatch("acceptInvitation", &["invitation", receipt]).unwrap();
	assert_eq!(accepted.target(&invited).unwrap().role, custody::Role::Offer);
	assert_eq!(accepted.mutation.verb, "claimInvitation");
	assert_eq!(accepted.mutation.args, [receipt]);
	assert!(accepted.target(&intent).is_err());
	for invalid in [
		"receipt",
		"00112233445566778899aabbccddeeFF",
		"00112233445566778899aabbccddee",
		"00112233445566778899aabbccddeeff00",
	] {
		assert!(dispatch("acceptInvitation", &["invitation", invalid]).is_err());
	}
	let mut visit = raw.clone();
	visit["conversations"][0]["access"] = serde_json::Value::Null;
	visit["conversations"][0]["accepted"] = json!(key::<custody::AcceptedAccess>(22, 23));
	let visit = workspace::Intent::decode(&visit.to_string()).unwrap();
	let inbox = serde_json::to_string(&key::<custody::RoomInbox>(1, 1)).unwrap();
	assert_eq!(
		dispatch("joinRoom", &["conversation", "member", &inbox])
			.unwrap()
			.target(&visit)
			.unwrap()
			.role,
		custody::Role::AcceptedAccess
	);
	let mut ambiguous = raw.clone();
	ambiguous["conversations"][0]["accepted"] = json!(key::<custody::AcceptedAccess>(22, 23));
	let ambiguous = workspace::Intent::decode(&ambiguous.to_string()).unwrap();
	assert!(
		dispatch("joinRoom", &["conversation", "member", &inbox])
			.unwrap()
			.target(&ambiguous)
			.is_err()
	);
	// Public recovery selects independently retained directory authority and the
	// original publication. A newer directory row cannot retarget this witness.
	let mut public = raw.clone();
	public["conversations"][0]["access"] = serde_json::Value::Null;
	public["conversations"][0]["publicEntry"] = json!({
		"access": key::<custody::DirectoryAccess>(30,31),
	});
	public["conversations"][0]["publication"] = json!("exact-publication");
	public["directories"][0]["access"] = json!(key::<custody::DirectoryAccess>(32, 33));
	let public = workspace::Intent::decode(&public.to_string()).unwrap();
	let (target, mutation) = dispatch("joinRoom", &["conversation", "member", &inbox])
		.unwrap()
		.bind(&public)
		.unwrap();
	assert_eq!(target.role, custody::Role::DirectoryAccess);
	assert_eq!(target.key.slot().get(), 30);
	assert_eq!(mutation.verb, "subscribePublication");
	assert_eq!(mutation.args, ["exact-publication", "member"]);
	assert_eq!(mutation.reply, rooms_application::session::effect::Reply::Membership);
	let mut linked_public = raw.clone();
	linked_public["conversations"][0]["control"] = serde_json::Value::Null;
	linked_public["conversations"][0]["access"] = serde_json::Value::Null;
	linked_public["conversations"][0]["publicEntry"] = json!({
		"access": key::<custody::DirectoryAccess>(30, 31),
	});
	linked_public["conversations"][0]["publication"] = json!("exact-publication");
	let linked_public = workspace::Intent::decode(&linked_public.to_string()).unwrap();
	let (target, mutation) = dispatch("ensureRoomLink", &["conversation"])
		.unwrap()
		.bind(&linked_public)
		.unwrap();
	assert_eq!(target.role, custody::Role::DirectoryAccess);
	assert_eq!(target.key.slot().get(), 30);
	assert_eq!(mutation.verb, "linkPublication");
	let mut descriptive = linked_public.clone();
	let workspace::Conversation::Room(room) = &mut descriptive.conversations.as_mut_slice()[0] else {
		panic!("room")
	};
	room.public_entry = None;
	assert!(
		dispatch("ensureRoomLink", &["conversation"])
			.unwrap()
			.bind(&descriptive)
			.is_err()
	);
	assert!(
		dispatch("joinRoom", &["conversation", "member", &inbox])
			.unwrap()
			.bind(&descriptive)
			.is_err()
	);
	assert_eq!(mutation.args, ["exact-publication"]);
	assert_eq!(mutation.reply, rooms_application::session::effect::Reply::RoomLink);
	let creation = dispatch(
		"openManagedRoom",
		&[
			"directory",
			"New room",
			"listed",
			"open",
			"moderated",
			"~11111111111111111111111111111111",
		],
	)
	.unwrap();
	assert_eq!(creation.target(&intent).unwrap().role, custody::Role::DirectoryAccess);
	assert_eq!(creation.mutation.verb, "openManaged");
	assert_eq!(creation.mutation.args.len(), 5);
	assert!(creation.target(&workspace::Intent::empty()).is_err());
	let callback = serde_json::to_string(&key::<custody::RoomInbox>(12, 13)).unwrap();
	let membership = dispatch("joinRoom", &["conversation", "member", &callback]).unwrap();
	let targets = membership.targets(&intent).unwrap();
	assert_eq!(targets.len(), 2);
	assert_eq!(targets[0].role, custody::Role::RoomAccess);
	assert_eq!(targets[1].role, custody::Role::RoomInbox);
	assert_eq!(
		(targets[1].key.slot().get(), targets[1].key.generation().get()),
		(12, 13)
	);
	assert_eq!(membership.mutation.verb, "subscribe");
	assert_eq!(membership.mutation.args, ["member"]);
	assert!(membership.dependent_argument());
	let stale = serde_json::to_string(&key::<custody::RoomInbox>(12, 14)).unwrap();
	assert!(
		dispatch("joinRoom", &["conversation", "member", &stale])
			.unwrap()
			.targets(&intent)
			.is_err()
	);
	let mut missing = intent.clone();
	let workspace::Conversation::Room(room) = &mut missing.conversations.as_mut_slice()[0] else {
		unreachable!()
	};
	room.inbox = None;
	assert!(membership.targets(&missing).is_err());
	let shared = serde_json::to_string(&key::<custody::RoomAccess>(16, 17)).unwrap();
	let publisher = serde_json::to_string(&custody::Coordinate {
		role: custody::Role::Operations,
		key: key::<()>(30, 31),
	})
	.unwrap();
	let publication = dispatch("publishPeeredRoom", &["directory", "Shared room", &shared, &publisher]).unwrap();
	let targets = publication.targets(&intent).unwrap();
	assert_eq!(targets.len(), 2);
	assert_eq!(targets[0].role, custody::Role::Operations);
	assert_eq!(targets[1].role, custody::Role::RoomAccess);
	assert_eq!(
		(targets[1].key.slot().get(), targets[1].key.generation().get()),
		(16, 17)
	);
	assert!(
		!publication.dependent_argument(),
		"direct sharing keeps exact held authority"
	);
	assert_eq!(publication.mutation.verb, "publishDurableRoom");
	assert_eq!(publication.mutation.args, ["Shared room"]);
	assert!(dispatch("publishPeeredRoom", &["directory", "", &shared, &publisher]).is_err());
	assert!(
		dispatch(
			"publishPeeredRoom",
			&["directory", "Shared room", "a bearer URI", &publisher]
		)
		.is_err()
	);
	let mut shared_intent = intent.clone();
	let mut direct = fixture();
	direct["conversations"] = json!([{
		"kind": "direct", "id": "direct", "directory": "directory", "peer": "peer",
		"access": key::<custody::DirectAccess>(18, 19), "closed": false, "draft": ""
	}]);
	let direct = workspace::Intent::decode(&direct.to_string()).unwrap();
	shared_intent
		.conversations
		.try_push(direct.conversations.as_slice()[0].clone())
		.unwrap();
	let offer = dispatch("offerRoom", &["conversation", "direct"]).unwrap();
	let direct_post = dispatch("say", &["direct", "a message"]).unwrap();
	assert_eq!(
		direct_post.target(&shared_intent).unwrap().role,
		custody::Role::DirectAccess
	);
	let (_, sent) = direct_post.bind(&shared_intent).unwrap();
	assert_eq!(sent.verb, "dm");
	assert_eq!(sent.args, ["a message"]);
	let caption = "See https://example.org/";
	let previews = "[\"https://example.org/\"]";
	let (_, sent) = dispatch("say", &["direct", caption, previews])
		.unwrap()
		.bind(&shared_intent)
		.unwrap();
	assert_eq!(sent.verb, "dm");
	assert_eq!(sent.args, [caption, rooms_application::open_graph::WIRE_TAG, previews]);
	let (_, sent) = dispatch("say", &["conversation", caption, previews])
		.unwrap()
		.bind(&shared_intent)
		.unwrap();
	assert_eq!(sent.verb, rooms_application::room::correlation::POST);
	assert_eq!(sent.args, [caption, previews, "effect"]);
	let (_, sent) = dispatch("say", &["conversation", caption, "[]"])
		.unwrap()
		.bind(&shared_intent)
		.unwrap();
	assert_eq!(sent.verb, rooms_application::room::correlation::POST);
	assert_eq!(sent.args, [caption, "[]", "effect"]);
	for args in [
		vec!["conversation", caption, "null"],
		vec!["conversation", "no link", previews],
		vec!["conversation", caption, "[]", "[]"],
	] {
		assert!(dispatch("say", &args).is_err());
	}
	let targets = offer.targets(&shared_intent).unwrap();
	assert_eq!(targets.len(), 2);
	assert_eq!(targets[0].role, custody::Role::DirectAccess);
	assert_eq!(targets[1].role, custody::Role::RoomAccess);
	assert_eq!(
		(targets[0].key.slot().get(), targets[0].key.generation().get()),
		(18, 19)
	);
	assert!(!offer.dependent_argument());
	let (_, mutation) = offer.bind(&shared_intent).unwrap();
	assert_eq!(mutation.verb, "handRoom");
	assert_eq!(mutation.args, ["room"]);
	for failure in ["closed", "directory", "missing-room", "missing-direct"] {
		let mut changed = shared_intent.clone();
		let workspace::Conversation::Direct(row) = &mut changed.conversations.as_mut_slice()[1] else {
			panic!("direct");
		};
		match failure {
			"closed" => row.closed = true,
			"directory" => row.directory = rooms_application::fields::Text::new("another".into()).unwrap(),
			"missing-direct" => row.access = None,
			_ => {
				let workspace::Conversation::Room(row) = &mut changed.conversations.as_mut_slice()[0] else {
					panic!("room");
				};
				row.access = None;
			}
		}
		assert!(
			dispatch("offerRoom", &["conversation", "direct"])
				.unwrap()
				.targets(&changed)
				.is_err(),
			"{failure}"
		);
		if matches!(failure, "closed" | "missing-direct") {
			assert!(
				dispatch("say", &["direct", "a message"])
					.unwrap()
					.target(&changed)
					.is_err()
			);
		}
	}
	assert!(dispatch("offerRoom", &["conversation"]).is_err());
	assert!(dispatch("offerRoom", &["conversation", "direct", "bearer"]).is_err());
	for (name, args, verb, role, expected) in [
		(
			"setRoomAway",
			vec!["conversation", "away"],
			"away",
			custody::Role::RoomSeat,
			(6, 7),
		),
		(
			"say",
			vec!["conversation", "hello"],
			"post",
			custody::Role::RoomSeat,
			(6, 7),
		),
		(
			"setRoomSubject",
			vec!["conversation", "subject"],
			"setSubject",
			custody::Role::RoomSubject,
			(8, 9),
		),
		(
			"editLine",
			vec!["conversation", "23", "edit"],
			"edit",
			custody::Role::Line,
			(10, 11),
		),
		(
			"withdrawLine",
			vec!["conversation", "23"],
			"withdraw",
			custody::Role::Line,
			(10, 11),
		),
		(
			"ensureRoomLink",
			vec!["conversation"],
			"link",
			custody::Role::RoomControl,
			(2, 3),
		),
		(
			"issueRoomModerator",
			vec!["conversation"],
			"giveSteward",
			custody::Role::RoomControl,
			(2, 3),
		),
		(
			"kickRoomMember",
			vec!["conversation", "peer"],
			"kick",
			custody::Role::RoomAccess,
			(4, 5),
		),
		(
			"revokeManagedRoomAuthority",
			vec!["conversation", "room", "\"00000000000000010000000000000001\""],
			"revokeRoomLink",
			custody::Role::RoomControl,
			(2, 3),
		),
		(
			"revokeManagedRoomAuthority",
			vec!["conversation", "steward", "\"00000000000000040000000000000005\""],
			"revokeSteward",
			custody::Role::RoomControl,
			(2, 3),
		),
		(
			"unregisterManagedRoom",
			vec!["conversation"],
			"unregisterRoom",
			custody::Role::RoomControl,
			(2, 3),
		),
		(
			"setManagedRoomPolicy",
			vec!["conversation", "listed", "open", "moderated"],
			"setRoomPolicy",
			custody::Role::RoomControl,
			(2, 3),
		),
	] {
		let dispatch = dispatch(name, &args).unwrap();
		assert_eq!(dispatch.mutation.verb, verb);
		let target = dispatch.target(&intent).unwrap();
		assert_eq!(target.role, role);
		assert_eq!((target.key.slot().get(), target.key.generation().get()), expected);
		assert!(dispatch.target(&workspace::Intent::empty()).is_err());
		let mut changed = intent.clone();
		let workspace::Conversation::Room(room) = &mut changed.conversations.as_mut_slice()[0] else {
			panic!("room");
		};
		room.moderator = None;
		room.control = None;
		room.seat = None;
		room.subject = None;
		room.lines = rooms_application::fields::List::default();
		if name == "ensureRoomLink" {
			assert_eq!(
				dispatch.target(&changed).unwrap().role,
				custody::Role::RoomAccess,
				"saving an existing link asks the held entrance; it cannot issue management"
			);
		} else {
			assert!(
				dispatch.target(&changed).is_err(),
				"missing moderation or control cannot fall back to room entry"
			);
		}
	}
	let selected = serde_json::to_string(&key::<custody::RoomAccess>(4, 5)).unwrap();
	let revocation = dispatch("revokeManagedRoomAuthority", &["conversation", "steward", &selected]).unwrap();
	assert!(revocation.revokes_selected());
	assert_eq!(revocation.targets(&intent).unwrap().len(), 2);
	let stale = serde_json::to_string(&key::<custody::RoomAccess>(4, 6)).unwrap();
	assert!(
		dispatch("revokeManagedRoomAuthority", &["conversation", "steward", &stale])
			.unwrap()
			.targets(&intent)
			.is_err()
	);
	let expected = serde_json::to_string(&key::<custody::RoomSeat>(6, 7)).unwrap();
	let retirement = dispatch("retireRoomMembership", &["conversation", &expected]).unwrap();
	assert!(retirement.retires_membership());
	assert_eq!(retirement.mutation.verb, "leave");
	assert!(retirement.mutation.args.is_empty());
	assert_eq!(retirement.target(&intent).unwrap().role, custody::Role::RoomSeat);
	let stale = serde_json::to_string(&key::<custody::RoomSeat>(6, 8)).unwrap();
	assert!(
		dispatch("retireRoomMembership", &["conversation", &stale])
			.unwrap()
			.target(&intent)
			.is_err()
	);
	for args in [
		vec!["conversation"],
		vec!["conversation", "bearer"],
		vec!["conversation", &expected, "extra"],
	] {
		assert!(dispatch("retireRoomMembership", &args).is_err());
	}
	let maximum = "😀".repeat(60);
	let expected = serde_json::to_string(&key::<custody::PublicationLease>(14, 15)).unwrap();
	let publication = dispatch("revokePeeredRoom", &["publication", &expected]).unwrap();
	assert!(publication.retires_publication() && !publication.retires_membership());
	assert_eq!(publication.mutation.verb, "revoke");
	assert!(publication.mutation.args.is_empty());
	let target = publication.target(&intent).unwrap();
	assert_eq!(target.role, custody::Role::PublicationLease);
	assert_eq!((target.key.slot().get(), target.key.generation().get()), (14, 15));
	assert!(target.role.live(), "publication leases are connection-lived");
	assert!(publication.target(&workspace::Intent::empty()).is_err());
	let stale = serde_json::to_string(&key::<custody::PublicationLease>(14, 16)).unwrap();
	assert!(
		dispatch("revokePeeredRoom", &["publication", &stale])
			.unwrap()
			.target(&intent)
			.is_err()
	);
	for args in [
		vec!["publication"],
		vec!["publication", "bearer"],
		vec!["publication", &expected, "extra"],
	] {
		assert!(dispatch("revokePeeredRoom", &args).is_err());
	}
	assert!(dispatch("setRoomAway", &["conversation", &maximum]).is_ok());
	assert!(dispatch("setRoomAway", &["conversation", &(maximum + "x")]).is_err());
	for (name, args) in [
		(
			"openManagedRoom",
			vec!["directory", "New room", "listed", "open", "moderated", "wrong-key"],
		),
		(
			"openManagedRoom",
			vec![
				"directory",
				"",
				"listed",
				"open",
				"moderated",
				"~11111111111111111111111111111111",
			],
		),
		(
			"openManagedRoom",
			vec![
				"directory",
				"New room",
				"invalid",
				"open",
				"moderated",
				"~11111111111111111111111111111111",
			],
		),
		("joinRoom", vec!["conversation", "member"]),
		("joinRoom", vec!["conversation", "room", &callback]),
		("joinRoom", vec!["conversation", "member", "ocapn://bearer"]),
		("editLine", vec!["conversation", "0", "edit"]),
		("editLine", vec!["conversation", "9007199254740992", "edit"]),
		("withdrawLine", vec!["conversation", "23", "bearer"]),
		("say", vec!["conversation"]),
		("setRoomSubject", vec!["conversation"]),
		("ensureRoomLink", vec![]),
		("ensureRoomLink", vec!["conversation", "bearer"]),
		("issueRoomModerator", vec![]),
		("issueRoomModerator", vec!["conversation", "bearer"]),
		("kickRoomMember", vec!["conversation", ""]),
		("kickRoomMember", vec!["conversation"]),
		("revokeManagedRoomAuthority", vec!["conversation", "manager", "token"]),
		("revokeManagedRoomAuthority", vec!["conversation", "room", ""]),
		("revokeManagedRoomAuthority", vec!["conversation", "room"]),
		("unregisterManagedRoom", vec![]),
		("unregisterManagedRoom", vec!["conversation", "token"]),
		("setManagedRoomPolicy", vec!["conversation", "secret", "open", "open"]),
		("setManagedRoomPolicy", vec!["conversation", "listed", "open"]),
	] {
		assert!(dispatch(name, &args).is_err());
	}
	let (_, mutation) = dispatch("setManagedRoomPolicy", &["conversation", "listed", "open", "moderated"])
		.unwrap()
		.bind(&intent)
		.unwrap();
	let workspace::Conversation::Room(room) = &intent.conversations.as_slice()[0] else {
		panic!("room");
	};
	assert_eq!(
		mutation
			.args
			.last()
			.and_then(rooms_application::session::effect::Argument::text),
		room.name.text().as_str()
	);
	assert_eq!(mutation.reply, rooms_application::session::effect::Reply::RoomPolicy);
	assert!(
		dispatch("editLine", &["conversation", "24", "edit"])
			.unwrap()
			.target(&intent)
			.is_err()
	);
}
