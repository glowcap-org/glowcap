//! The recovery's four-permission union is checked by a real derived session:
//! withholding any one refuses before the seat is read or the operator runs.
use super::{
	super::*,
	rig::{Rig, Spec},
};
use rooms_application::content::permissions::Permission::{
	InteractWorkspace, ManageCustody, ObserveWorkspace, ReplaceWorkspace, UseOperations,
};

impl Rig {
	/// A session derived with `permissions` submits the recovery as itself.
	async fn derived_recover(&self, id: &str, permissions: &[u64]) -> Option<Argument> {
		let policy = rooms_glowcap::policy::descriptor().unwrap();
		let terms = policy.value_for_kind(session::KIND, permissions, &[]).unwrap();
		let (source, _) = self.owner.derive(terms, 1, ControlPowers::default()).await.unwrap();
		let rest = self.arguments(self.access, self.seat);
		let base = self.base().await;
		let mut args = vec![id.into(), base.into(), "recoverRoomManager".into()];
		args.extend(rest.into_iter().map(Argument::from));
		match mutate(&self.host, &source, "command", &args).await {
			Ok(_) => Some(finished(&self.host, &self.root, id, &source).await),
			Err(_) => None,
		}
	}
}

// Every supported permission but one is held, for each of the four in turn.
// The exact union reaches the seat and operator.
scenario!(manager_recovery_requires_each_permission_of_its_union, async {
	let union = [InteractWorkspace, UseOperations, ManageCustody, ReplaceWorkspace];
	for withheld in union {
		let rig = Rig::open("manager-recovery-permission", Spec::REMOTE).await;
		let held: Vec<u64> = session::SUPPORTED
			.iter()
			.filter(|permission| **permission != withheld && permission.prerequisite() != Some(withheld))
			.map(|permission| permission.key())
			.collect();
		let outcome = rig.derived_recover("withheld", &held).await;
		assert_ne!(
			outcome.as_ref().and_then(Argument::as_str),
			Some("committed"),
			"{withheld:?} withheld still committed"
		);
		assert_eq!(
			(rig.peers.seat_reads.get(), rig.peers.operator_calls.get()),
			(0, 0),
			"{withheld:?} withheld reached a peer"
		);
		assert!(rig.room().await.control.is_none());
		rig.close().await;
	}
	// The neighbor holds exactly the union and the observation they all need.
	let rig = Rig::open("manager-recovery-permission-union", Spec::REMOTE).await;
	let exact: Vec<u64> = union
		.iter()
		.chain(&[ObserveWorkspace])
		.map(|permission| permission.key())
		.collect();
	let outcome = rig.derived_recover("exact", &exact).await;
	assert_eq!(outcome.as_ref().and_then(Argument::as_str), Some("committed"));
	assert_eq!((rig.peers.seat_reads.get(), rig.peers.operator_calls.get()), (1, 1));
	rig.close().await;
});
