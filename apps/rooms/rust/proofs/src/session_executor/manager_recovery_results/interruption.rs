//! Interrupting the worker's observation, its private settlement or the whole
//! session never repeats a read or the operator dispatch.
use super::{
	super::{environment, *},
	rig::{Rig, Spec},
};

// The operator answered and the receipt's private settlement is refused. The
// result stays unresolved across retries, and issuance happens only once.
scenario!(
	manager_recovery_retains_an_unsettled_result_without_repeating_issuance,
	async {
		let rig = Rig::open("manager-recovery-settlement", Spec::REMOTE).await;
		let rest = rig.arguments(rig.access, rig.seat);
		rig.refuse_settlement.set(true);
		assert_eq!(rig.recover("settled", &rest).await.unwrap().as_str(), Some("unknown"));
		assert_eq!((rig.peers.seat_reads.get(), rig.peers.operator_calls.get()), (1, 1));
		for _ in 0..3 {
			rig.owner.resume_pending().unwrap();
			environment::yield_turn().await;
		}
		assert_eq!(rig.status("settled").await.as_str(), Some("unknown"));
		assert_eq!((rig.peers.seat_reads.get(), rig.peers.operator_calls.get()), (1, 1));
		rig.refuse_settlement.set(false);
		assert_eq!(rig.finish("settled").await.as_str(), Some("committed"));
		assert_eq!(
			(rig.peers.seat_reads.get(), rig.peers.operator_calls.get()),
			(1, 1),
			"a settled retry repeated a call"
		);
		assert!(rig.reports.borrow().is_empty(), "{:?}", rig.reports.borrow());
		rig.close().await;
	}
);
// A restart while the effect is unresolved grants no replay: the cold receipt
// stays unresolved and no peer is asked again. A session cannot close around a
// worker still parked at a peer, so each case starts once its worker finished.
scenario!(manager_recovery_grants_no_replay_after_a_cold_restart, async {
	for (label, mismatched) in [("unsettled after issuance", false), ("a manager of another room", true)] {
		let rig = Rig::open("manager-recovery-cold", Spec::REMOTE).await;
		let rest = rig.arguments(rig.access, rig.seat);
		if mismatched {
			*rig.peers.governs.borrow_mut() = "another-room".into();
		} else {
			rig.refuse_settlement.set(true);
		}
		assert_eq!(
			rig.recover("cold", &rest).await.unwrap().as_str(),
			Some("unknown"),
			"{label}"
		);
		assert_eq!(
			(rig.peers.seat_reads.get(), rig.peers.operator_calls.get()),
			(1, 1),
			"{label}"
		);
		let peers = rig.peers.clone();
		let cold = rig.go_cold().await;
		let status = finished(&cold.host, &cold.root, "cold", &cold.root).await;
		assert_eq!(status.as_str(), Some("unknown"), "{label}: a cold receipt resolved");
		for _ in 0..3 {
			cold.owner.resume_pending().unwrap();
			environment::yield_turn().await;
		}
		assert_eq!(
			(peers.seat_reads.get(), peers.operator_calls.get()),
			(1, 1),
			"{label}: a cold resume asked a peer again"
		);
		assert_eq!(
			finished(&cold.host, &cold.root, "cold", &cold.root).await.as_str(),
			Some("unknown")
		);
		assert_eq!(peers.entrance_calls.get(), 0, "{label}");
		cold.close().await;
	}
});
