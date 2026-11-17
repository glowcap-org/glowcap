//! The landing through the real result submit, one predicate of the admitted
//! room at a time: its publication, its row, its id and its replaced seat.
use super::{
	super::*,
	rig::{Rig, Spec, first_room, manager},
};

fn public() -> Spec {
	Spec {
		public: true,
		..Spec::REMOTE
	}
}

// A public-entry room is the publication its request named. Another publication
// in the same row, with the entry coordinate unchanged, is another room.
scenario!(manager_recovery_refuses_a_changed_publication, async {
	let rig = Rig::open("manager-recovery-publication", public()).await;
	let rest = rig.arguments(None, rig.seat);
	assert_eq!(
		rig.recover("published", &rest).await.unwrap().as_str(),
		Some("committed")
	);
	rig.replace_row(None, |room| {
		room.publication = Some(rooms_application::fields::Text::new("republished".into()).unwrap())
	})
	.await;
	let refused = rig
		.land("published", &rest, &[], |intent| {
			first_room(intent).control = Some(manager())
		})
		.await;
	assert!(refused.is_err(), "a row with another publication landed");
	assert!(rig.room().await.control.is_none());
	rig.close().await;
});

// The row the request was admitted for is gone, and a candidate that brings a
// row with the same id back does not stand in for it.
scenario!(manager_recovery_refuses_a_missing_original_row, async {
	let rig = Rig::open("manager-recovery-missing-row", Spec::REMOTE).await;
	let rest = rig.arguments(rig.access, rig.seat);
	assert_eq!(rig.recover("missing", &rest).await.unwrap().as_str(), Some("committed"));
	let original = rig.intent.clone();
	let mut without = original.clone();
	without.conversations = List::new(Vec::new()).unwrap();
	rig.owner.replace_workspace(&without).await.unwrap();
	let refused = rig
		.land("missing", &rest, &[], |intent| {
			let mut back = original;
			first_room(&mut back).control = Some(manager());
			intent.conversations = back.conversations;
		})
		.await;
	assert!(refused.is_err(), "a result landed without its admitted row");
	assert_eq!(rig.peers.operator_calls.get(), 1);
	rig.close().await;
});

// Two rows with one id are refused by workspace validation when the candidate
// is submitted, and the result stays held.
scenario!(manager_recovery_refuses_a_duplicated_room_id, async {
	let rig = Rig::open("manager-recovery-duplicate-id", Spec::REMOTE).await;
	let rest = rig.arguments(rig.access, rig.seat);
	assert_eq!(rig.recover("twin", &rest).await.unwrap().as_str(), Some("committed"));
	let refused = rig
		.land("twin", &rest, &[], |intent| {
			first_room(intent).control = Some(manager());
			let mut rows = intent.conversations.as_slice().to_vec();
			rows.push(rows[0].clone());
			intent.conversations = List::new(rows).unwrap();
		})
		.await;
	assert!(refused.is_err(), "two rows with one id landed");
	assert!(rig.room().await.control.is_none());
	rig.close().await;
});

// The entrance holds the room, so a seat replaced by another authority while
// the entrance stays still lands, with no seat read and no second issuance.
scenario!(
	manager_recovery_lands_after_the_seat_is_replaced_beside_its_entrance,
	async {
		let rig = Rig::open("manager-recovery-seat-replaced", Spec::REMOTE).await;
		let rest = rig.arguments(rig.access, rig.seat);
		assert_eq!(
			rig.recover("replaced", &rest).await.unwrap().as_str(),
			Some("committed")
		);
		let (other, _) = rig.another().await;
		rig.swap_custody(rig.seat, Some((other, None))).await;
		rig.land("replaced", &rest, &[], |intent| {
			first_room(intent).control = Some(manager())
		})
		.await
		.unwrap();
		assert!(rig.room().await.control.is_some());
		assert_eq!((rig.peers.seat_reads.get(), rig.peers.operator_calls.get()), (1, 1));
		rig.close().await;
	}
);

// The old generic request that carried a manager identity is no longer a
// command: it is refused at admission and reaches no peer.
scenario!(manager_recovery_refuses_the_old_operator_command, async {
	let rig = Rig::open("manager-recovery-old-command", Spec::REMOTE).await;
	let operator = serde_json::to_string(&rig.operator.key).unwrap();
	let base = rig.base().await;
	let args = [
		"old".into(),
		base.into(),
		"operator".into(),
		operator.into(),
		"giveManager".into(),
		super::rig::IDENTITY.into(),
	];
	assert!(mutate(&rig.host, &rig.root, "command", &args).await.is_err());
	assert_eq!(
		(rig.peers.seat_reads.get(), rig.peers.operator_calls.get()),
		(0, 0),
		"an old recovery reached a peer"
	);
	assert!(rig.room().await.control.is_none());
	rig.close().await;
});
