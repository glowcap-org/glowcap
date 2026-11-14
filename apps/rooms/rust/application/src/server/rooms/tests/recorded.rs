//! A managed room opens as the authority records it, whether or not it is
//! live, so no live room contradicts the record its manager keeps.
use super::*;

const ID: &str = "~0000000000000000000000000000000a";

#[test]
fn a_recorded_managed_room_does_not_open_under_another_name_or_policy() {
	let mut world = World::new(false);
	world.register(ID, "Salon", RoomPolicy::Private);
	let open = |world: &mut World, name: &str, policy: RoomPolicy| {
		world.rooms.open(
			1,
			Open {
				name,
				policy,
				recovery: Some(ID),
				managed: true,
			},
			fresh(10),
			&world.authority,
		)
	};
	for (name, policy) in [("Salon", RoomPolicy::Open), ("Parlor", RoomPolicy::Private)] {
		let refused = open(&mut world, name, policy).err().unwrap();
		assert_eq!(
			refused.reason(),
			"this room is recorded with another name or policy, and its manager changes them",
			"{name} {policy:?}"
		);
	}
	assert!(
		world.rooms.enter("Salon", &world.authority).is_err(),
		"the room stays unlisted"
	);
	assert!(open(&mut world, "Salon", RoomPolicy::Private).is_ok());
}
