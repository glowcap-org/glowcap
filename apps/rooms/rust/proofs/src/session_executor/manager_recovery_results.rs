//! Manager recovery reads the witnessed seat's identity, then dispatches the
//! operator once with that identity alone. The fake exporter counts every call
//! each peer receives, so each scenario asserts what reached which peer.
#[macro_use]
mod rig;
mod basis;
mod cold;
mod dependent;
mod exporters;
mod interruption;
mod landing;
mod permissions;

use self::rig::{Home, IDENTITY, Rig, Spec, Stage};
use super::{requests::coordinate, *};

scenario!(
	manager_recovery_reads_once_dispatches_once_with_the_identity_alone,
	async {
		let rig = Rig::open("manager-recovery-happy", Spec::REMOTE).await;
		let rest = rig.arguments(rig.access, rig.seat);
		let status = rig.recover("recovered", &rest).await.unwrap();
		assert_eq!(status.as_str(), Some("committed"), "{:?}", rig.reports.borrow());
		assert_eq!(rig.peers.seat_reads.get(), 1, "one identity read");
		assert_eq!(rig.peers.operator_calls.get(), 1, "one operator dispatch");
		assert_eq!(
			&*rig.peers.operator_args.borrow(),
			&[vec![IDENTITY.to_owned()]],
			"the identity is the sole wire argument"
		);
		assert_eq!(rig.peers.entrance_calls.get(), 0, "the entrance is never invoked");
		rig.close().await;
	}
);

// Every operator and seat pairing the content layer can resolve to one exporter.
scenario!(manager_recovery_compares_the_exporters_of_operator_and_seat, async {
	let local = Rig::open(
		"manager-recovery-local",
		Spec {
			operator: Home::Local,
			seat: Home::Local,
			..Spec::REMOTE
		},
	)
	.await;
	let rest = local.arguments(local.access, local.seat);
	assert_eq!(local.recover("local", &rest).await.unwrap().as_str(), Some("committed"));
	assert_eq!((local.peers.seat_reads.get(), local.peers.operator_calls.get()), (1, 1));
	local.close().await;
	for (label, spec) in [
		(
			"operator remote, seat local",
			Spec {
				operator: Home::Remote,
				seat: Home::Local,
				..Spec::REMOTE
			},
		),
		(
			"operator local, seat remote",
			Spec {
				operator: Home::Local,
				seat: Home::Remote,
				..Spec::REMOTE
			},
		),
	] {
		let rig = Rig::open("manager-recovery-mismatch", spec).await;
		let rest = rig.arguments(rig.access, rig.seat);
		assert!(rig.recover("mismatch", &rest).await.is_err(), "{label} was admitted");
		assert_eq!(
			(rig.peers.seat_reads.get(), rig.peers.operator_calls.get()),
			(0, 0),
			"{label} reached a peer"
		);
		rig.close().await;
	}
});
// A recovery with no entrance is held by its seat.
scenario!(manager_recovery_without_an_entrance_is_held_by_its_seat, async {
	let rig = Rig::open(
		"manager-recovery-seat-only",
		Spec {
			entrance: false,
			..Spec::REMOTE
		},
	)
	.await;
	let rest = rig.arguments(None, rig.seat);
	assert_eq!(rig.recover("seated", &rest).await.unwrap().as_str(), Some("committed"));
	assert_eq!(rig.peers.operator_calls.get(), 1);
	rig.close().await;
});
// A witness that no longer matches the room row reaches no peer.
scenario!(manager_recovery_refuses_a_stale_witness_before_any_peer_call, async {
	let rig = Rig::open("manager-recovery-stale", Spec::REMOTE).await;
	let stale_seat = coordinate(custody::Role::RoomSeat, 2);
	for (label, rest) in [
		("a seat the row does not hold", rig.arguments(rig.access, stale_seat)),
		(
			"an entrance the row does not hold",
			rig.arguments(Some(coordinate(custody::Role::RoomAccess, 2)), rig.seat),
		),
		("no entrance for an entranced row", rig.arguments(None, rig.seat)),
	] {
		assert!(rig.recover("stale", &rest).await.is_err(), "{label} was admitted");
		assert_eq!(
			(rig.peers.seat_reads.get(), rig.peers.operator_calls.get()),
			(0, 0),
			"{label} reached a peer"
		);
	}
	rig.close().await;
});
// The identity is bounded and nonempty before it is owned, and a refusal
// before the operator is dispatched settles without any operator call.
scenario!(
	manager_recovery_validates_the_identity_before_the_operator_runs,
	async {
		for (label, identity, dispatched) in [
			("empty", String::new(), 0),
			("one over the bound", "a".repeat(32769), 0),
			("mid", "a".repeat(8000), 1),
			("at the bound", "a".repeat(32768), 1),
		] {
			let rig = Rig::open("manager-recovery-size", Spec::REMOTE).await;
			rig.peers.answer(identity.clone());
			*rig.peers.governs.borrow_mut() = identity;
			let rest = rig.arguments(rig.access, rig.seat);
			let status = rig.recover("sized", &rest).await.unwrap();
			assert_eq!(
				rig.peers.operator_calls.get(),
				dispatched,
				"{label}: {status:?} {:?}",
				rig.reports.borrow()
			);
			assert_eq!(rig.peers.seat_reads.get(), 1, "{label}");
			assert_eq!(
				status.as_str() == Some("committed"),
				dispatched == 1,
				"{label}: {status:?}"
			);
			rig.close().await;
		}
		let rig = Rig::open("manager-recovery-terminal", Spec::REMOTE).await;
		*rig.peers.identity.borrow_mut() = Err("the seat cannot answer".into());
		let rest = rig.arguments(rig.access, rig.seat);
		let status = rig.recover("terminal", &rest).await.unwrap();
		assert_ne!(status.as_str(), Some("committed"));
		assert_eq!(
			rig.peers.operator_calls.get(),
			0,
			"a terminal read refusal never reaches the operator"
		);
		rig.close().await;
	}
);
// A manager that governs another room is an unknown outcome diagnosed once,
// and a retry never repeats issuance or re-reads the answer.
scenario!(manager_recovery_settles_a_mismatched_manager_unknown_once, async {
	let rig = Rig::open("manager-recovery-governs", Spec::REMOTE).await;
	*rig.peers.governs.borrow_mut() = "another-room".into();
	let rest = rig.arguments(rig.access, rig.seat);
	let status = rig.recover("governs", &rest).await.unwrap();
	assert_eq!(status.as_str(), Some("unknown"), "{:?}", rig.reports.borrow());
	assert_eq!(rig.peers.operator_calls.get(), 1);
	assert_eq!(
		rig.peers.governs_calls.get(),
		1,
		"the answer was asked what it governs once"
	);
	let reported = rig.reports.borrow().len();
	assert_eq!(
		reported,
		1,
		"the diagnostic is recorded once: {:?}",
		rig.reports.borrow()
	);
	for _ in 0..3 {
		rig.owner.resume_pending().unwrap();
		environment::yield_turn().await;
	}
	assert_eq!(rig.peers.operator_calls.get(), 1, "issuance is never repeated");
	assert_eq!(
		rig.peers.governs_calls.get(),
		1,
		"a permanent mismatch is never acquired again"
	);
	assert_eq!(
		rig.reports.borrow().len(),
		reported,
		"a permanent mismatch is not re-diagnosed"
	);
	rig.close().await;
});

// An observation that times out in each phase leaves its work retained.
// Resuming completes it with one read and one dispatch, never a second.
scenario!(manager_recovery_resumes_each_interrupted_phase_exactly_once, async {
	// Before the identity read leaves: the read is retained and sent once.
	let rig = Rig::open("manager-recovery-phase-read", Spec::REMOTE).await;
	let rest = rig.arguments(rig.access, rig.seat);
	// Admission restores the exact references over the connection, so the
	// worker waits until the transport is parked.
	rig.platform.suspended.set(true);
	rig.submit("phase", &rest).await.unwrap();
	rig.gate.block();
	rig.observe_briefly();
	rig.platform.suspended.set(false);
	rig.gate.parked().await;
	// A confirmed receipt whose work has not settled reads as unknown.
	tokio::time::sleep(std::time::Duration::from_millis(300)).await;
	assert_eq!(rig.status("phase").await.as_str(), Some("unknown"));
	assert!(rig.gate.observed(), "the identity read parked at the transport");
	assert_eq!((rig.peers.seat_reads.get(), rig.peers.operator_calls.get()), (0, 0));
	assert_eq!(rig.finish("phase").await.as_str(), Some("committed"));
	assert_eq!((rig.peers.seat_reads.get(), rig.peers.operator_calls.get()), (1, 1));
	rig.close().await;
	// After the identity is read: the operator call parks, then runs once.
	// After the operator answers: the manager acquisition parks, and issuance never repeats.
	for stage in [Stage::Seat, Stage::Operator] {
		let rig = Rig::open("manager-recovery-phase", Spec::REMOTE).await;
		rig.peers.park.set(Some(stage));
		rig.observe_briefly();
		let rest = rig.arguments(rig.access, rig.seat);
		assert_eq!(rig.recover("phase", &rest).await.unwrap().as_str(), Some("unknown"));
		assert!(rig.gate.observed(), "the next call parked at the transport");
		let (reads, calls) = (rig.peers.seat_reads.get(), rig.peers.operator_calls.get());
		assert_eq!(reads, 1);
		assert_eq!(calls, usize::from(stage == Stage::Operator));
		assert_eq!(rig.finish("phase").await.as_str(), Some("committed"));
		assert_eq!(
			(rig.peers.seat_reads.get(), rig.peers.operator_calls.get()),
			(1, 1),
			"a resumed phase repeated a call"
		);
		rig.close().await;
	}
});
