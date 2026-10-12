//! A dropped connection and an explicit room departure have different roster effects.
use super::*;

#[test]
fn disconnect_keeps_offline_presence_but_releases_the_live_seat() {
	let mut world = World::new(false);
	let entrance = world.open(1, "Garden", RoomPolicy::Open);
	world.join(1, &entrance, "Alice");
	let bob = world.join(2, &entrance, "Bob").membership;
	let effects = world.rooms.connection_closed(2);
	let heard = notices(&effects, 1);
	assert!(
		!heard
			.iter()
			.any(|notice| matches!(notice, Notice::Leave { nick, .. } if nick == "Bob"))
	);
	assert!(
		heard
			.iter()
			.any(|notice| matches!(notice, Notice::Offline { names, count: 1 } if names.as_ref() == ["Bob"]))
	);
	assert_eq!(world.rooms.member_count(&entrance.room), 1);
	assert!(world.rooms.membership_kind(&entrance.room, bob).is_err());
	assert!(effects.releases.contains(&Release {
		connection: 2,
		capability: "Bob-inbox"
	}));
	let arrival = world.join(3, &entrance, "Carol");
	assert!(
		notices(&arrival.effects, 3)
			.iter()
			.any(|notice| matches!(notice, Notice::Offline { names, count: 2 } if names.as_ref() == ["Bob"]))
	);
}

#[test]
fn explicit_leave_is_gone_and_a_return_replaces_offline_spelling() {
	let mut world = World::new(false);
	let entrance = world.open(1, "Garden", RoomPolicy::Open);
	world.join(1, &entrance, "Alice");
	let bob = world.join(2, &entrance, "Bob").membership;
	let left = world.rooms.leave(&entrance.room, bob).unwrap();
	assert!(matches!(notices(&left, 1)[0], Notice::Leave { nick, .. } if nick == "Bob"));
	assert!(world.rooms.rooms[&entrance.room].offline.is_empty());
	world.join(2, &entrance, "Bob");
	world.rooms.connection_closed(2);
	world.directory.connection_closed(2);
	let returned = world.join(3, &entrance, "bob");
	let heard = notices(&returned.effects, 1);
	assert!(matches!(heard[0], Notice::Forgotten(nick) if nick == "Bob"));
	assert!(matches!(heard[1], Notice::Join { nick, count: 2 } if nick == "bob"));
	assert!(world.rooms.rooms[&entrance.room].offline.is_empty());
	assert!(
		world.rooms.connection_closed(2).tells.is_empty(),
		"a stale disconnect cannot mark the successor offline"
	);
	world.rooms.leave(&entrance.room, returned.membership).unwrap();
	let arrival = world.join(4, &entrance, "Carol");
	assert!(
		!notices(&arrival.effects, 4)
			.iter()
			.any(|notice| matches!(notice, Notice::Offline { .. }))
	);
}

#[test]
fn offline_churn_is_bounded_and_a_subscription_receives_one_batch() {
	let mut world = World::new(false);
	let entrance = world.open(1, "Garden", RoomPolicy::Open);
	world.join(1, &entrance, "Alice");
	for index in 0..=MAX_ROOM_OFFLINE {
		let connection = index as u32 + 2;
		world.join(connection, &entrance, &format!("member-{index}"));
		let effects = world.rooms.connection_closed(connection);
		if index == MAX_ROOM_OFFLINE {
			assert!(matches!(notices(&effects, 1)[0], Notice::Forgotten(nick) if nick == "member-0"));
			assert_eq!(
				notices(&effects, 1)[0].said(),
				"",
				"eviction cannot narrate an explicit departure"
			);
		}
	}
	assert_eq!(world.rooms.rooms[&entrance.room].offline.len(), MAX_ROOM_OFFLINE);
	let arrival = world.join(1000, &entrance, "Carol");
	let heard = notices(&arrival.effects, 1000);
	let batches: Vec<_> = heard
		.iter()
		.filter_map(|notice| match notice {
			Notice::Offline { names, count: 2 } => Some(names),
			_ => None,
		})
		.collect();
	assert_eq!(
		batches.len(),
		1,
		"offline replay cannot exhaust the message-count budget"
	);
	assert_eq!(batches[0].len(), MAX_ROOM_OFFLINE);
	assert_eq!(batches[0].first().unwrap(), "member-1");
	assert!(heard.len() < 10);
}

#[test]
fn disconnect_notices_share_one_body_across_recipients() {
	let mut world = World::new(false);
	let entrance = world.open(1, "Garden", RoomPolicy::Open);
	world.join(1, &entrance, "Alice");
	world.join(2, &entrance, "Bob");
	world.join(3, &entrance, "Carol");
	let effects = world.rooms.connection_closed(2);
	let (Notice::Offline { names: first, .. }, Notice::Offline { names: second, .. }) =
		(notices(&effects, 1)[0], notices(&effects, 3)[0])
	else {
		panic!("both observers must hear the disconnect");
	};
	assert!(
		alloc::sync::Arc::ptr_eq(first, second),
		"fan-out must not copy the presence body"
	);
}

#[test]
fn replaced_connection_cannot_mark_its_successor_offline() {
	let mut world = World::new(false);
	let entrance = world.open(1, "Garden", RoomPolicy::Open);
	world.join(1, &entrance, "Alice");
	world.join(2, &entrance, "Bob");
	let successor = world
		.rooms
		.subscribe(
			3,
			&entrance,
			"Bob",
			"new-inbox",
			None,
			"new-seat",
			None,
			&mut world.directory,
			|a, b| (a, b) == (2, 3),
			&world.authority,
			None,
		)
		.unwrap();
	assert!(world.rooms.connection_closed(2).tells.is_empty());
	assert_eq!(world.rooms.member_count(&entrance.room), 2);
	assert!(
		world
			.rooms
			.membership_kind(&entrance.room, successor.membership)
			.is_ok()
	);
	assert!(world.rooms.rooms[&entrance.room].offline.is_empty());
}

#[test]
fn offline_names_end_with_their_room_generation() {
	let mut world = World::new(false);
	let entrance = world.open(1, "Garden", RoomPolicy::Open);
	world.join(1, &entrance, "Alice");
	world.join(2, &entrance, "Bob");
	world.rooms.connection_closed(2);
	assert_eq!(world.rooms.rooms[&entrance.room].offline.len(), 1);
	world.rooms.connection_closed(1);
	assert!(!world.rooms.rooms.contains_key(&entrance.room));
	let next = world.open(3, "Garden", RoomPolicy::Open);
	let arrival = world.join(3, &next, "Carol");
	assert!(world.rooms.rooms[&next.room].offline.is_empty());
	assert!(
		!notices(&arrival.effects, 3)
			.iter()
			.any(|notice| matches!(notice, Notice::Offline { .. }))
	);
}

#[test]
fn typing_renews_a_bounded_lease_and_unchanged_away_is_coalesced() {
	let mut world = World::new(false);
	let entrance = world.open(1, "Garden", RoomPolicy::Open);
	let alice = world.join(1, &entrance, "Alice").membership;
	world.join(2, &entrance, "Bob");
	assert!(
		!world
			.rooms
			.typing_at(&entrance.room, alice, true, 0)
			.unwrap()
			.tells
			.is_empty()
	);
	assert!(
		world
			.rooms
			.typing_at(&entrance.room, alice, true, 1)
			.unwrap()
			.tells
			.is_empty()
	);
	assert!(
		!world
			.rooms
			.typing_at(&entrance.room, alice, true, 2500)
			.unwrap()
			.tells
			.is_empty()
	);
	assert!(
		world
			.rooms
			.typing_at(&entrance.room, alice, false, 8000)
			.unwrap()
			.tells
			.is_empty()
	);
	assert!(world.rooms.away_needed(&entrance.room, alice, "away").unwrap());
	world.rooms.away(&entrance.room, alice, "away").unwrap();
	assert!(!world.rooms.away_needed(&entrance.room, alice, "away").unwrap());
}
