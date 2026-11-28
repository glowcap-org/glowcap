//! A dropped connection and an explicit room departure have different roster effects.
use super::*;
use crate::room::membership::{TYPING_CLEAR_MS, TYPING_RENEW_MS, TYPING_REPEAT_MS};

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
	let relayed = |world: &World, on: bool, now: u64| {
		!world
			.rooms
			.typing_at(&entrance.room, alice, on, now)
			.unwrap()
			.tells
			.is_empty()
	};
	assert!(relayed(&world, true, 0));
	assert!(
		!relayed(&world, true, TYPING_REPEAT_MS - 1),
		"a start the room just relayed is not news"
	);
	// The latest a client can start its renewal clock with nothing relayed.
	// The lease's own ordering holds its renewal inside the readers' wait.
	let renewed = TYPING_REPEAT_MS - 1 + TYPING_RENEW_MS;
	assert!(
		relayed(&world, true, renewed),
		"that client's renewal reaches the readers"
	);
	assert!(
		relayed(&world, true, renewed + TYPING_RENEW_MS),
		"and so does the next, each one inside the wait a reader gives the last"
	);
	let lapsed = renewed + TYPING_RENEW_MS + TYPING_CLEAR_MS;
	assert!(
		!relayed(&world, false, lapsed),
		"a stop for a level every reader already dropped is not news"
	);
	assert!(relayed(&world, true, lapsed));
	assert!(
		relayed(&world, false, lapsed + TYPING_CLEAR_MS - 1),
		"a stop is relayed for as long as a reader still shows the level"
	);
	assert!(world.rooms.away_needed(&entrance.room, alice, "away").unwrap());
	world.rooms.away(&entrance.room, alice, "away").unwrap();
	assert!(!world.rooms.away_needed(&entrance.room, alice, "away").unwrap());
}

#[test]
fn a_posted_line_ends_its_authors_typing_without_a_notice() {
	let mut world = World::new(false);
	let entrance = world.open(1, "Garden", RoomPolicy::Open);
	let alice = world.join(1, &entrance, "Alice").membership;
	world.join(2, &entrance, "Bob");
	world.rooms.typing_at(&entrance.room, alice, true, 0).unwrap();
	let (_, posted) = world.rooms.post(&entrance.room, alice, "hello", 100).unwrap();
	assert!(
		posted
			.effects
			.tells
			.iter()
			.all(|tell| !matches!(tell.notice, Notice::Typing { .. })),
		"the line is the only notice a post sends"
	);
	// The lease is over: a stop has nothing left to say, and the next start
	// is told at once, where an unbroken lease would coalesce it.
	assert!(!world.rooms.typing_needed(&entrance.room, alice, false, 101).unwrap());
	assert!(
		!world
			.rooms
			.typing_at(&entrance.room, alice, true, 102)
			.unwrap()
			.tells
			.is_empty()
	);
}

#[test]
fn a_profile_belongs_to_one_participant_seat_even_when_the_name_continues() {
	use crate::room::profile::MemberProfile;
	let mut world = World::new(false);
	let room = world.open(1, "Garden", RoomPolicy::Open);
	let other = world.open(2, "Study", RoomPolicy::Open);
	let first = world.join(1, &room, "Alice").membership;
	world.join(2, &room, "Bob");
	world.join(1, &other, "Alice");
	world.join(3, &other, "Carol");

	let bot = MemberProfile::parse("bot", "Reviewing").unwrap();
	let update = world.rooms.set_profile(&room.room, first, bot.clone()).unwrap();
	assert_eq!(update.tells.iter().map(|t| t.connection).collect::<Vec<_>>(), [1, 2]);
	assert!(update.events.is_empty());
	assert!(
		world
			.rooms
			.set_profile(&room.room, first, bot.clone())
			.unwrap()
			.tells
			.is_empty()
	);

	let observe = world
		.rooms
		.mint_invitation(&room.room, first, MembershipKind::Observer)
		.unwrap();
	let observer = world
		.rooms
		.claim_invitation(observe, "0123456789abcdef0123456789abcdef")
		.unwrap();
	let watching = world.join(4, &observer, "Observer");
	assert!(notices(&watching.effects, 4).iter().any(
		|notice| matches!(notice, Notice::Profile { nick, profile: Some(profile) } if nick == "Alice" && **profile == bot)
	));
	assert_eq!(
		world
			.rooms
			.set_profile(&room.room, watching.membership, bot.clone())
			.unwrap_err()
			.code,
		Some(FailureCode::ReadOnlyMembership)
	);
	let unchanged = world.join(1, &room, "Alice");
	assert!(
		notices(&unchanged.effects, 2)
			.iter()
			.any(|n| matches!(n, Notice::Profile {nick,profile: None} if nick == "Alice"))
	);
	assert!(
		!notices(&unchanged.effects, 2)
			.iter()
			.any(|n| matches!(n, Notice::Join { .. } | Notice::Leave { .. }))
	);
	world
		.rooms
		.set_profile(&room.room, unchanged.membership, bot.clone())
		.unwrap();
	let replacement = world.join(1, &room, "ALICE");
	assert!(
		notices(&replacement.effects, 2)
			.iter()
			.any(|n| matches!(n, Notice::Join {nick, ..} if nick == "ALICE"))
	);
	assert!(
		notices(&replacement.effects, 2)
			.iter()
			.any(|notice| matches!(notice, Notice::Profile { nick, profile: None } if nick == "Alice"))
	);
	assert_eq!(
		world
			.rooms
			.set_profile(&room.room, first, bot.clone())
			.unwrap_err()
			.code,
		Some(FailureCode::NotRoomMember)
	);
	assert!(
		world
			.rooms
			.set_profile(&room.room, replacement.membership, MemberProfile::default())
			.unwrap()
			.tells
			.is_empty()
	);
	let late = world.join(5, &room, "Late");
	assert!(
		!notices(&late.effects, 5)
			.iter()
			.any(|n| matches!(n, Notice::Profile { .. }))
	);
	let other_late = world.join(6, &other, "AlsoLate");
	assert!(
		!notices(&other_late.effects, 6)
			.iter()
			.any(|n| matches!(n, Notice::Profile { .. }))
	);
}

#[test]
fn a_full_room_introduces_all_incumbents_in_two_bounded_batches() {
	use crate::room::profile::{MAX_ABOUT, MAX_BATCH, MemberProfile};
	let mut world = World::new(false);
	let room = world.open(1, "Garden", RoomPolicy::Open);
	let introduction = MemberProfile::parse("assisted", &"界".repeat(MAX_ABOUT)).unwrap();
	for who in 1..MAX_ROOM_MEMBERS {
		let seat = world.join(who as u32, &room, &format!("Nick{who}")).membership;
		world.rooms.set_profile(&room.room, seat, introduction.clone()).unwrap();
	}
	let joining = MAX_ROOM_MEMBERS as u32;
	let arrival = world.join(joining, &room, "Reader");
	let chunks = notices(&arrival.effects, joining)
		.into_iter()
		.filter_map(|notice| match notice {
			Notice::Profiles(entries) => Some(entries),
			Notice::Profile { .. } => panic!("full room split off an unnecessary single introduction"),
			_ => None,
		})
		.collect::<Vec<_>>();
	assert_eq!(chunks.len(), 2);
	let mut count = 0;
	for chunk in chunks {
		assert!(chunk.len() <= MAX_BATCH);
		for (name, profile) in chunk.iter() {
			count += 1;
			assert_eq!(name, &format!("Nick{count}"));
			assert_eq!(profile.as_ref(), &introduction);
		}
	}
	assert_eq!(count, MAX_ROOM_MEMBERS - 1);
}
