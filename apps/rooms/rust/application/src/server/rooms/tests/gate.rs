//! A public entrance means what the room's name offers the public now: its
//! gate closes for anyone not seated when the policy stops offering the kind
//! the entrance was minted with.
use super::*;

const ID: &str = "~00000000000000000000000000000009";

/// A live managed room under `policy`, and the by-name entrance it offers.
fn live(world: &mut World, policy: RoomPolicy) -> Entrance {
	world.register(ID, "Salon", policy);
	let dormant = world.rooms.enter("salon", &world.authority).unwrap();
	world.join(1, &dormant, "Owner");
	let entrance = world.rooms.enter("salon", &world.authority).unwrap();
	assert_eq!(
		entrance.gate,
		Gate::Public,
		"a live listed room enters by its public gate"
	);
	entrance
}

fn repolicy(world: &mut World, name: &str, policy: RoomPolicy) {
	world.authority = world
		.authority
		.with_managed_room_policy(ID, name, policy)
		.unwrap()
		.unwrap();
	world.rooms.policy_changed(ID, &world.authority).unwrap();
}

/// The room does not eject a member through a gate that closed, and the pass
/// holds for the kind the member is seated as. A participant entrance does not
/// seat a stranger, or someone who has since taken a watching seat.
#[test]
fn an_open_rooms_participant_entrance_closes_when_the_room_turns_moderated() {
	let mut world = World::new(false);
	let entrance = live(&mut world, RoomPolicy::Open);
	assert_eq!(entrance.kind, MembershipKind::Participant);
	let seated = world.join(2, &entrance, "Bob");
	assert_eq!(seated.kind, MembershipKind::Participant);
	repolicy(&mut world, "Salon", RoomPolicy::Moderated);
	assert!(
		!world.rooms.offered(&entrance, &world.authority),
		"the entrance seats nobody new"
	);
	assert!(
		!world.rooms.gate_open(3, &entrance, &world.authority),
		"a stranger is refused"
	);
	assert!(
		world.rooms.gate_open(2, &entrance, &world.authority),
		"a member seated through it passes"
	);
	let subscribe = |world: &mut World, connection: u32, nick: &str| {
		world
			.rooms
			.subscribe(
				connection,
				&entrance,
				nick,
				"i",
				None,
				"s",
				None,
				&mut world.directory,
				same,
				&world.authority,
				Some(fresh(9)),
			)
			.unwrap_err()
			.refusal
			.reason()
	};
	let withdrawn = "no-such-room: this room entrance is no longer offered";
	assert_eq!(subscribe(&mut world, 3, "Eve"), withdrawn);
	let watching = world.rooms.enter("Salon", &world.authority).unwrap();
	assert_eq!(
		watching.kind,
		MembershipKind::Observer,
		"the name now offers a watching seat"
	);
	world.join(2, &watching, "Bob");
	assert!(
		!world.rooms.gate_open(2, &entrance, &world.authority),
		"Bob now sits as an observer, which the participant entrance does not offer"
	);
	assert_eq!(subscribe(&mut world, 2, "Bob"), withdrawn);
	assert!(world.rooms.gate_open(2, &watching, &world.authority));
}

/// An entrance means what the name offers now, so an observer entrance to a
/// room that has since opened to speakers closes as well: the holder enters
/// again and is seated as what the name offers.
#[test]
fn a_moderated_rooms_observer_entrance_closes_when_the_room_opens() {
	let mut world = World::new(false);
	let entrance = live(&mut world, RoomPolicy::Moderated);
	assert_eq!(entrance.kind, MembershipKind::Observer);
	repolicy(&mut world, "Salon", RoomPolicy::Open);
	assert!(!world.rooms.gate_open(3, &entrance, &world.authority));
	assert_eq!(
		world.rooms.enter("Salon", &world.authority).unwrap().kind,
		MembershipKind::Participant
	);
}

/// A managed room's generation starts again when the room is forgotten and
/// registered again. An entrance from the earlier registration is open only
/// where it is what the room offers the public now.
#[test]
fn an_entrance_from_before_a_forget_means_what_the_room_offers_now() {
	for (again, offered) in [
		(RoomPolicy::Moderated, false),
		(RoomPolicy::Private, false),
		(RoomPolicy::Open, true),
	] {
		let mut world = World::new(false);
		world.register(ID, "Salon", RoomPolicy::Open);
		let entrance = world.rooms.enter("salon", &world.authority).unwrap();
		assert_eq!(
			entrance.gate,
			Gate::Managed {
				id: ID.into(),
				generation: 1
			}
		);
		assert_eq!(entrance.kind, MembershipKind::Participant);
		world.authority = world.authority.with_room_forgotten(ID).unwrap().unwrap();
		assert!(
			!world.rooms.offered(&entrance, &world.authority),
			"a forgotten room offers nothing"
		);
		world.register(ID, "Salon", again);
		assert_eq!(
			world.authority.managed_room(ID).unwrap().generation,
			1,
			"the generation starts again"
		);
		assert_eq!(world.rooms.offered(&entrance, &world.authority), offered, "{again:?}");
	}
}
