//! The session installs the receiving side of a direct conversation a
//! collaborator opened. It writes on its private channel through that
//! collaborator's grant, while the collaborator still cannot manage custody.
//! The supervised install is the session's own, and the channel refuses a
//! forged witness, a grant that cannot participate, a paused or revoked
//! grant, and any write other than the one inbox an install sets.
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
	owner
		.import(
			requests::coordinate(custody::Role::SessionAccess, 181),
			collaborator.clone(),
			None,
		)
		.await
		.unwrap();
	// The collaborator's open row, its fields edited by `edit`.
	let edited = |intent: &workspace::Intent, edit: &dyn Fn(&mut workspace::Direct)| {
		let mut intent = intent.clone();
		let row = intent
			.conversations
			.as_mut_slice()
			.iter_mut()
			.find_map(|row| match row {
				workspace::Conversation::Direct(row) if !row.closed => Some(row.as_mut()),
				_ => None,
			})
			.expect("the collaborator's direct conversation is open");
		edit(row);
		(row.clone(), intent)
	};
	let source = custody::FieldKey::new(NonZeroU64::new(181).unwrap(), NonZeroU64::new(1).unwrap());
	let (row, intent) = edited(&through(root).snapshot().await.unwrap().intent, &|row| {
		row.source = Some(source)
	});
	owner.replace_workspace(&intent).await.unwrap();
	let before = workspace.snapshot().await.unwrap();
	let inbox = custody::FieldKey::new(NonZeroU64::new(50).unwrap(), NonZeroU64::new(1).unwrap());
	let installed = |intent: &workspace::Intent, inbox| edited(intent, &|row| row.inbox = Some(inbox)).1;
	let candidate = installed(&before.intent, inbox);
	let callback = host.spawn(|_, _| Ok(Argument::Void)).unwrap();
	let import = |role| {
		vec![Import {
			coordinate: custody::Coordinate::new(role, inbox),
			reference: callback.clone(),
			uri: None,
		}]
	};
	let refused = async |workspace: &Workspace<Platform>,
	                     witness: Option<&Ref>,
	                     (role, candidate): (custody::Role, &workspace::Intent),
	                     refusal: &str| {
		let acquisition = match witness {
			None => workspace.prepare_acquisition(before.revision, import(role), &[], candidate),
			Some(witness) => {
				workspace.prepare_owner_acquisition(witness, before.revision, import(role), &[], candidate)
			}
		};
		let error = acquisition.unwrap().submit().await.unwrap_err().to_string();
		assert!(error.ends_with(&format!(": {refusal}")), "{refusal}: {error}");
		assert_eq!(
			through(root).snapshot().await.unwrap().revision,
			before.revision,
			"{refusal}"
		);
	};
	let shape = "a private continuation installs one inbox or retires a lost connection";
	let inbox_role = custody::Role::DirectInbox;
	// A collaborator's own acquisition needs custody management, only the
	// session root witnesses the private channel, and the session writes only
	// for a grant that participates.
	refused(&workspace, None, (inbox_role, &candidate), "Denied").await;
	refused(
		&workspace,
		Some(&collaborator),
		(inbox_role, &candidate),
		"ApplicationRefused",
	)
	.await;
	refused(&through(&observer), Some(root), (inbox_role, &candidate), "Denied").await;
	let mut moved = candidate.clone();
	moved.active = None;
	refused(&workspace, Some(root), (inbox_role, &moved), shape).await;
	refused(&workspace, Some(root), (custody::Role::RoomInbox, &candidate), shape).await;
	lifecycle(host, &control, "pause").await;
	refused(&workspace, Some(root), (inbox_role, &candidate), "Paused").await;
	lifecycle(host, &control, "resume").await;
	let mut membership = owner
		.supervise_direct(&row, &mut realization::Entropy::seeded(194), |_, _, _, _| {
			Ok(Argument::Void)
		})
		.await
		.unwrap();
	let supervised = loop {
		let now = through(root).snapshot().await.unwrap();
		if now.revision != before.revision {
			break now;
		}
		environment::yield_turn().await;
	};
	let (supervised_row, _) = edited(&supervised.intent, &|_| {});
	let supervised_inbox = supervised_row.inbox.expect("the session installed the receiving side");
	assert_eq!(
		supervised.intent,
		installed(&before.intent, supervised_inbox),
		"the install set that inbox and nothing else"
	);
	membership.close().await.unwrap();
	lifecycle(host, &control, "revoke").await;
	let after = through(root).snapshot().await.unwrap();
	let error = workspace
		.prepare_owner_acquisition(
			root,
			after.revision,
			import(inbox_role),
			&[],
			&installed(&after.intent, inbox),
		)
		.unwrap()
		.submit()
		.await
		.unwrap_err()
		.to_string();
	assert!(error.ends_with(": Revoked"), "{error}");
	assert_eq!(through(root).snapshot().await.unwrap().revision, after.revision);
}
