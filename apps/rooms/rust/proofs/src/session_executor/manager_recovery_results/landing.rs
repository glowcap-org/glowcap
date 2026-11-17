//! The committed manager result lands only in the room row its request named.
use super::{
	super::{requests::coordinate, *},
	rig::{Home, Rig, Spec, first_room, manager},
};

// The result lands in the admitted row after its seat is gone, since the
// entrance holds the room, and no seat is read to land it.
scenario!(manager_recovery_lands_in_its_row_without_reading_a_seat, async {
	let rig = Rig::open("manager-recovery-landing", Spec::REMOTE).await;
	let rest = rig.arguments(rig.access, rig.seat);
	assert_eq!(rig.recover("landing", &rest).await.unwrap().as_str(), Some("committed"));
	let reads = rig.peers.seat_reads.get();
	rig.land("landing", &rest, &[rig.seat], |intent| {
		let room = first_room(intent);
		room.seat = None;
		room.control = Some(manager());
	})
	.await
	.unwrap();
	assert_eq!(rig.peers.seat_reads.get(), reads, "landing reads no seat");
	assert_eq!(
		rig.peers.operator_calls.get(),
		1,
		"landing never dispatches the operator again"
	);
	let room = rig.room().await;
	assert!(
		room.control.is_some() && room.seat.is_none(),
		"the admitted row took the manager"
	);
	rig.close().await;
});
// A viewer that submits the same result a second time changes nothing.
scenario!(manager_recovery_landing_twice_is_a_no_op, async {
	let rig = Rig::open("manager-recovery-twice", Spec::REMOTE).await;
	let rest = rig.arguments(rig.access, rig.seat);
	assert_eq!(rig.recover("twice", &rest).await.unwrap().as_str(), Some("committed"));
	rig.land("twice", &rest, &[], |intent| {
		first_room(intent).control = Some(manager())
	})
	.await
	.unwrap();
	let before = rig.base().await;
	rig.land("twice", &rest, &[], |intent| {
		first_room(intent).control = Some(manager())
	})
	.await
	.unwrap();
	assert_eq!(
		rig.base().await,
		before,
		"the second viewer's landing changed no revision"
	);
	assert_eq!(rig.peers.operator_calls.get(), 1);
	rig.close().await;
});

// A result that no longer belongs to the room its request named stays held:
// the landing is refused and the row keeps what it had.
scenario!(
	manager_recovery_refuses_a_row_that_no_longer_matches_its_witness,
	async {
		let spare = |role, slot| coordinate(role, slot);
		// A competing manager arrived first.
		let rig = Rig::open("manager-recovery-competing", Spec::REMOTE).await;
		let rest = rig.arguments(rig.access, rig.seat);
		assert_eq!(rig.recover("raced", &rest).await.unwrap().as_str(), Some("committed"));
		rig.replace_row(Some(spare(custody::Role::RoomControl, 5)), |room| {
			room.control = Some(spare(custody::Role::RoomControl, 5).key.retag())
		})
		.await;
		assert!(
			rig.land("raced", &rest, &[], |intent| first_room(intent).control =
				Some(manager()))
				.await
				.is_err()
		);
		assert_eq!(
			rig.room().await.control.map(|key| key.slot().get()),
			Some(5),
			"the competing manager stays"
		);
		rig.close().await;
		// The entrance was replaced.
		let rig = Rig::open("manager-recovery-replaced", Spec::REMOTE).await;
		let rest = rig.arguments(rig.access, rig.seat);
		assert_eq!(
			rig.recover("replaced", &rest).await.unwrap().as_str(),
			Some("committed")
		);
		rig.replace_row(Some(spare(custody::Role::RoomAccess, 2)), |room| {
			room.access = Some(spare(custody::Role::RoomAccess, 2).key.retag())
		})
		.await;
		assert!(
			rig.land("replaced", &rest, &[], |intent| first_room(intent).control =
				Some(manager()))
				.await
				.is_err()
		);
		assert!(rig.room().await.control.is_none());
		rig.close().await;
		// Candidate fields the witness does not allow it to change.
		let rig = Rig::open("manager-recovery-candidate", Spec::REMOTE).await;
		let rest = rig.arguments(rig.access, rig.seat);
		assert_eq!(
			rig.recover("candidate", &rest).await.unwrap().as_str(),
			Some("committed")
		);
		let altered = rig
			.land("candidate", &rest, &[], |intent| {
				let room = first_room(intent);
				room.control = Some(manager());
				room.directory = rooms_application::fields::Text::new("elsewhere".into()).unwrap();
			})
			.await;
		assert!(altered.is_err(), "a candidate that moved the room was accepted");
		let duplicated = rig
			.land("candidate", &rest, &[], |intent| {
				first_room(intent).control = Some(manager());
				let mut rows = intent.conversations.as_slice().to_vec();
				let mut copy = rows[0].clone();
				if let session::workspace::Conversation::Room(room) = &mut copy {
					room.id = rooms_application::fields::Text::new("copy".into()).unwrap();
				}
				rows.push(copy);
				intent.conversations = List::new(rows).unwrap();
			})
			.await;
		assert!(duplicated.is_err(), "one destination held by two rooms was accepted");
		assert!(rig.room().await.control.is_none());
		rig.close().await;
		// With no entrance the seat holds the room, so losing it loses the room.
		let rig = Rig::open(
			"manager-recovery-seat-basis",
			Spec {
				entrance: false,
				..Spec::REMOTE
			},
		)
		.await;
		let rest = rig.arguments(None, rig.seat);
		assert_eq!(rig.recover("seated", &rest).await.unwrap().as_str(), Some("committed"));
		let lost = rig
			.land("seated", &rest, &[rig.seat], |intent| {
				let room = first_room(intent);
				room.seat = None;
				room.control = Some(manager());
			})
			.await;
		assert!(lost.is_err(), "a seat-held room landed after its seat was lost");
		rig.land("seated", &rest, &[], |intent| {
			first_room(intent).control = Some(manager())
		})
		.await
		.unwrap();
		rig.close().await;
	}
);
// The operator is needed to issue, never to land: a workspace that has since
// dropped it still takes the committed result.
scenario!(manager_recovery_lands_after_the_operator_is_removed, async {
	let rig = Rig::open("manager-recovery-operator-removed", Spec::REMOTE).await;
	let rest = rig.arguments(rig.access, rig.seat);
	assert_eq!(rig.recover("removed", &rest).await.unwrap().as_str(), Some("committed"));
	let operator = rig.operator;
	rig.land("removed", &rest, &[operator], |intent| {
		intent.operators = List::default();
		first_room(intent).control = Some(manager());
	})
	.await
	.unwrap();
	assert!(rig.room().await.control.is_some());
	assert_eq!(rig.peers.operator_calls.get(), 1);
	rig.close().await;
});

// A portable configuration export carries no seat. Restoring it with the
// original entrance held again from its link is the original room, and the
// recovery lands without a seat and without a second issuance.
scenario!(
	manager_recovery_lands_after_an_exported_configuration_is_restored,
	async {
		let rig = Rig::open("manager-recovery-exported", Spec::REMOTE).await;
		let rest = rig.arguments(rig.access, rig.seat);
		assert_eq!(
			rig.recover("exported", &rest).await.unwrap().as_str(),
			Some("committed")
		);
		rig.restore_exported(rig.access.unwrap()).await;
		assert!(rig.room().await.seat.is_none());
		rig.land("exported", &rest, &[], |intent| {
			first_room(intent).control = Some(manager())
		})
		.await
		.unwrap();
		assert!(rig.room().await.control.is_some());
		assert_eq!((rig.peers.seat_reads.get(), rig.peers.operator_calls.get()), (1, 1));
		rig.close().await;
	}
);

// A room entered through its directory's public entry is held by that entry.
// The entry stays on the directory's own exporter. The second case moves the
// operator and seat to another exporter (the peered directory), so the entry
// and the invoked targets are on distinct sessions: the entry is never an
// affinity input and is never invoked.
scenario!(manager_recovery_in_a_public_entry_room_lands_by_that_entry, async {
	for home in [Home::Remote, Home::Other] {
		let rig = Rig::open(
			"manager-recovery-public",
			Spec {
				operator: home,
				seat: home,
				public: true,
				..Spec::REMOTE
			},
		)
		.await;
		let rest = rig.arguments(None, rig.seat);
		assert_eq!(rig.recover("public", &rest).await.unwrap().as_str(), Some("committed"));
		assert_eq!(rig.peers.entrance_calls.get(), 0, "the public entry is never invoked");
		assert_eq!((rig.peers.seat_reads.get(), rig.peers.operator_calls.get()), (1, 1));
		rig.land("public", &rest, &[rig.seat], |intent| {
			let room = first_room(intent);
			room.seat = None;
			room.control = Some(manager());
		})
		.await
		.unwrap();
		assert!(rig.room().await.control.is_some());
		assert_eq!(rig.peers.seat_reads.get(), 1, "landing read a seat");
		rig.close().await;
	}
});

// The room is held by its actual authority, not by a coordinate or a string.
// Different authority at the same coordinate is another room, and the same
// authority held again is the original room.
scenario!(manager_recovery_lands_by_actual_custody_not_by_coordinate, async {
	// An entrance coordinate that now holds other authority refuses the landing.
	let rig = Rig::open("manager-recovery-entrance-swap", Spec::REMOTE).await;
	let rest = rig.arguments(rig.access, rig.seat);
	assert_eq!(rig.recover("swapped", &rest).await.unwrap().as_str(), Some("committed"));
	let access = rig.access.unwrap();
	rig.swap_custody(access, Some(rig.another().await)).await;
	let refused = rig
		.land("swapped", &rest, &[], |intent| {
			first_room(intent).control = Some(manager())
		})
		.await;
	assert!(refused.is_err(), "another authority at the entrance coordinate landed");
	assert!(rig.room().await.control.is_none());
	// Holding the original entrance authority again makes the room eligible.
	rig.swap_custody(access, None).await;
	rig.land("swapped", &rest, &[], |intent| {
		first_room(intent).control = Some(manager())
	})
	.await
	.unwrap();
	assert!(rig.room().await.control.is_some());
	assert_eq!(
		rig.peers.operator_calls.get(),
		1,
		"restoring the room never issues again"
	);
	rig.close().await;
	// With no entrance the seat is the basis, and other authority at its coordinate refuses.
	let rig = Rig::open(
		"manager-recovery-seat-swap",
		Spec {
			entrance: false,
			..Spec::REMOTE
		},
	)
	.await;
	let rest = rig.arguments(None, rig.seat);
	assert_eq!(rig.recover("rebound", &rest).await.unwrap().as_str(), Some("committed"));
	let (other, _) = rig.another().await;
	rig.swap_custody(rig.seat, Some((other, None))).await;
	let refused = rig
		.land("rebound", &rest, &[], |intent| {
			first_room(intent).control = Some(manager())
		})
		.await;
	assert!(refused.is_err(), "a rebound seat landed a seat-held room");
	assert!(rig.room().await.control.is_none());
	rig.close().await;
	// The same restore for a public-entry room, whose entry is the basis.
	let rig = Rig::open(
		"manager-recovery-public-swap",
		Spec {
			public: true,
			..Spec::REMOTE
		},
	)
	.await;
	let rest = rig.arguments(None, rig.seat);
	assert_eq!(rig.recover("public", &rest).await.unwrap().as_str(), Some("committed"));
	rig.swap_custody(rig.directory, Some(rig.another().await)).await;
	assert!(
		rig.land("public", &rest, &[], |intent| first_room(intent).control =
			Some(manager()))
			.await
			.is_err(),
		"another authority at the public entry coordinate landed"
	);
	rig.close().await;
});
