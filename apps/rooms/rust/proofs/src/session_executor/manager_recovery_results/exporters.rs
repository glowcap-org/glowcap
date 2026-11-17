//! Which sessions export the operator and the seat decides admission, before
//! the identity is read and before any operator runs.
use super::{
	super::environment,
	rig::{Home, Rig, Spec},
};

fn spec(operator: Home, seat: Home) -> Spec {
	Spec {
		operator,
		seat,
		..Spec::REMOTE
	}
}
// Two remote exporters on distinct sessions never share one recovery.
scenario!(manager_recovery_refuses_two_distinct_remote_exporters, async {
	for (operator, seat) in [(Home::Remote, Home::Other), (Home::Other, Home::Remote)] {
		let rig = Rig::open("manager-recovery-two-exporters", spec(operator, seat)).await;
		let rest = rig.arguments(rig.access, rig.seat);
		assert!(
			rig.recover("split", &rest).await.is_err(),
			"two exporters were admitted"
		);
		assert_eq!(
			(rig.peers.seat_reads.get(), rig.peers.operator_calls.get()),
			(0, 0),
			"a peer was reached"
		);
		rig.close().await;
	}
	// The same second exporter for both is one session, so it is admitted.
	let rig = Rig::open("manager-recovery-second-exporter", spec(Home::Other, Home::Other)).await;
	let rest = rig.arguments(rig.access, rig.seat);
	assert_eq!(rig.recover("same", &rest).await.unwrap().as_str(), Some("committed"));
	assert_eq!((rig.peers.seat_reads.get(), rig.peers.operator_calls.get()), (1, 1));
	rig.close().await;
});
// A seat whose session is gone reports no exporter, exactly like a local one,
// and its custody no longer resolves. Beside a local operator the refusal comes
// before the identity is read and before the operator is called.
scenario!(manager_recovery_refuses_a_stale_seat_beside_a_local_operator, async {
	let mut rig = Rig::open("manager-recovery-stale-seat", spec(Home::Local, Home::Remote)).await;
	let rest = rig.arguments(rig.access, rig.seat);
	rig.sever().await;
	let refusal = rig.recover("stale", &rest).await.unwrap_err();
	assert_eq!(refusal.message(), Some("UnknownCapability"), "{refusal:?}");
	assert_eq!(rig.peers.operator_calls.get(), 0, "the operator ran for a stale seat");
	assert_eq!(rig.peers.seat_reads.get(), 0, "a stale seat answered");
	assert!(rig.room().await.control.is_none());
	rig.close().await;
});
// Two local references report no exporter, so they are admitted together. A
// seat that then cannot answer its identity read refuses before the operator.
scenario!(manager_recovery_admits_local_custody_and_refuses_a_failed_read, async {
	let rig = Rig::open("manager-recovery-local-read", spec(Home::Local, Home::Local)).await;
	*rig.peers.identity.borrow_mut() = Err("the seat cannot answer".into());
	let rest = rig.arguments(rig.access, rig.seat);
	let status = rig.recover("local", &rest).await.unwrap();
	assert_eq!(
		status.as_str(),
		Some("unsent"),
		"known not sent: {:?}",
		rig.reports.borrow()
	);
	assert_eq!(rig.peers.seat_reads.get(), 1, "the local seat was asked once");
	assert_eq!(rig.peers.operator_calls.get(), 0, "a failed read reached the operator");
	rig.close().await;
});
// A seat held as a live facet reports the exporter of the seat it forwards to.
scenario!(manager_recovery_compares_a_dependent_seats_exporter, async {
	let rig = Rig::open(
		"manager-recovery-dependent",
		Spec {
			member: true,
			..Spec::REMOTE
		},
	)
	.await;
	let seat = rig.dependent_seat().await;
	let rest = rig.arguments(rig.access, seat);
	assert_eq!(
		rig.recover("dependent", &rest).await.unwrap().as_str(),
		Some("committed"),
		"{:?}",
		rig.reports.borrow()
	);
	assert_eq!(
		(rig.peers.seat_reads.get(), rig.peers.operator_calls.get()),
		(1, 1),
		"the facet forwarded one read to its remote seat"
	);
	assert_eq!(rig.peers.entrance_calls.get(), 0);
	rig.close().await;
	let rig = Rig::open(
		"manager-recovery-dependent-foreign",
		Spec {
			seat: Home::Other,
			member: true,
			..Spec::REMOTE
		},
	)
	.await;
	let seat = rig.dependent_seat().await;
	let rest = rig.arguments(rig.access, seat);
	assert!(
		rig.recover("foreign", &rest).await.is_err(),
		"a dependent seat on another session was admitted"
	);
	assert_eq!((rig.peers.seat_reads.get(), rig.peers.operator_calls.get()), (0, 0));
	rig.close().await;
});
