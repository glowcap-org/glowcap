//! The session installs the receiving side of a direct conversation a
//! collaborator opened. It writes on its private channel through that
//! collaborator's grant, while the collaborator still cannot manage custody.
use super::*;
use rooms_glowcap::client::workspace::{Import, Workspace};

pub(super) async fn run(host: &Host, owner: &managed::Session<Platform>, root: &Ref, platform: &Platform) {
	let policy = rooms_glowcap::policy::descriptor().unwrap();
	let derive = async |rights: &[Permission]| {
		let keys: Vec<_> = rights.iter().map(|right| right.key()).collect();
		let terms = policy.value_for_kind(session::KIND, &keys, &[]).unwrap();
		owner.derive(terms, 1, full_control(terms)).await.unwrap()
	};
	let (collaborator, control) = derive(&[Permission::ObserveWorkspace, Permission::InteractWorkspace]).await;
	let (observer, _) = derive(&[Permission::ObserveWorkspace]).await;
	let through = |grant: &Ref| Workspace::local(host.clone(), platform.clone(), grant.clone());
	let workspace = through(&collaborator);
	let before = workspace.snapshot().await.unwrap();
	let inbox = custody::FieldKey::new(NonZeroU64::new(50).unwrap(), NonZeroU64::new(1).unwrap());
	let mut candidate = before.intent.clone();
	candidate
		.conversations
		.as_mut_slice()
		.iter_mut()
		.find_map(|row| match row {
			workspace::Conversation::Direct(row) if !row.closed => Some(row),
			_ => None,
		})
		.expect("the collaborator's direct conversation is open")
		.inbox = Some(inbox);
	let callback = host.spawn(|_, _| Ok(Argument::Void)).unwrap();
	let imports = || {
		vec![Import {
			coordinate: custody::Coordinate::new(custody::Role::DirectInbox, inbox),
			reference: callback.clone(),
			uri: None,
		}]
	};
	let refused = async |workspace: &Workspace<Platform>, witness: Option<&Ref>, why: &str| {
		let acquisition = match witness {
			None => workspace.prepare_acquisition(before.revision, imports(), &[], &candidate),
			Some(witness) => workspace.prepare_owner_acquisition(witness, before.revision, imports(), &[], &candidate),
		};
		assert!(acquisition.unwrap().submit().await.is_err(), "{why}");
		assert_eq!(
			through(root).snapshot().await.unwrap().revision,
			before.revision,
			"{why}"
		);
	};
	refused(
		&workspace,
		None,
		"a collaborator's own acquisition needs custody management",
	)
	.await;
	refused(
		&workspace,
		Some(&collaborator),
		"only the session root witnesses the private channel",
	)
	.await;
	refused(
		&through(&observer),
		Some(root),
		"the session writes only for a participating grant",
	)
	.await;
	lifecycle(host, &control, "pause").await;
	refused(&workspace, Some(root), "a paused grant stops the session's write too").await;
	lifecycle(host, &control, "resume").await;
	workspace
		.prepare_owner_acquisition(root, before.revision, imports(), &[], &candidate)
		.unwrap()
		.submit()
		.await
		.unwrap();
	assert_eq!(workspace.snapshot().await.unwrap().intent, candidate);
}
