//! Select a committed membership and its exact result custody in one revision.
use super::*;
use rooms_application::content::permissions::Permission;
use rooms_glowcap::client::{
	access::Control,
	workspace::{ResultImport, Workspace},
};

pub(super) async fn membership(
	host: &Host,
	owner: &managed::Session<Platform>,
	source: &Ref,
	canonical: &str,
	actual: &[Ref],
	refuse: &Cell<bool>,
	management: (&Ref, &loam::Policy, loam::PolicyValue),
) {
	let workspace = Workspace::local(host.clone(), Platform::default(), source.clone());
	let (id, base, name, args): (String, u64, String, Vec<String>) = serde_json::from_str(canonical).unwrap();
	let command = workspace.prepare_command(&id, base, &name, &args).await.unwrap();
	assert_eq!(command.canonical(), canonical);
	let snapshot = workspace.snapshot().await.unwrap();
	let original = snapshot.intent.clone();
	let mut intent = snapshot.intent;
	let session::workspace::Conversation::Room(room) = &mut intent.conversations.as_mut_slice()[0] else {
		panic!("membership room")
	};
	let field = |role, slot| custody::Coordinate {
		role,
		key: custody::FieldKey::new(NonZeroU64::new(slot).unwrap(), NonZeroU64::new(1).unwrap()),
	};
	let mut mappings = vec![ResultImport {
		result: field(custody::Role::RoomSeat, 1),
		destination: field(custody::Role::RoomSeat, 9),
	}];
	let source_key =
		custody::FieldKey::<custody::SessionAccess>::new(NonZeroU64::new(9).unwrap(), NonZeroU64::new(1).unwrap());
	room.source = Some(source_key);
	room.seat = Some(custody::FieldKey::new(
		NonZeroU64::new(9).unwrap(),
		NonZeroU64::new(1).unwrap(),
	));
	let result = command.result().await.unwrap();
	let fields = result.as_list().unwrap()[1].as_list().unwrap();
	for role in [custody::Role::RoomSubject, custody::Role::RoomFiles] {
		let exists = fields.iter().any(|entry| {
			custody::Coordinate::decode(entry.as_list().unwrap()[0].as_str().unwrap())
				.unwrap()
				.role == role
		});
		let selected = exists.then(|| field(role, 9).key);
		match role {
			custody::Role::RoomSubject => {
				room.subject = selected.map(|key| custody::FieldKey::new(key.slot(), key.generation()))
			}
			custody::Role::RoomFiles => {
				room.files = selected.map(|key| custody::FieldKey::new(key.slot(), key.generation()))
			}
			_ => unreachable!(),
		}
		if exists {
			mappings.push(ResultImport {
				result: field(role, 1),
				destination: field(role, 9),
			});
		}
	}
	let mut invalid = intent.clone();
	let session::workspace::Conversation::Room(room) = &mut invalid.conversations.as_mut_slice()[0] else {
		unreachable!()
	};
	room.seat = Some(custody::FieldKey::new(
		NonZeroU64::new(10).unwrap(),
		NonZeroU64::new(1).unwrap(),
	));
	let refused = command
		.prepare_result_acquisition_with_source(snapshot.revision, &mappings, &[], &invalid, Some(source_key))
		.unwrap();
	assert!(refused.submit().await.is_err());
	assert_eq!(
		workspace.snapshot().await.unwrap().revision,
		snapshot.revision,
		"invalid selection imports no field"
	);
	let stale = command
		.prepare_result_acquisition_with_source(snapshot.revision, &mappings, &[], &intent, Some(source_key))
		.unwrap();
	// A detour through another standing restores the same choices behind a
	// newer intent fence, so the result prepared before it is stale.
	let mut detour = original.clone();
	detour.standing = rooms_application::fields::Text::new("detour".into()).unwrap();
	owner.replace_workspace(&detour).await.unwrap();
	owner.replace_workspace(&original).await.unwrap();
	let snapshot = workspace.snapshot().await.unwrap();
	assert_eq!(snapshot.intent, original);
	assert!(matches!(
		stale.submit().await,
		Err(rooms_glowcap::client::Error::WorkspaceConflict)
	));
	assert_eq!(workspace.snapshot().await.unwrap().revision, snapshot.revision);
	let acquisition = command
		.prepare_result_acquisition_with_source(snapshot.revision, &mappings, &[], &intent, Some(source_key))
		.unwrap();
	let (control, policy, full) = management;
	let manager = Control::local(host.clone(), Platform::default(), control.clone());
	for missing in [Permission::ManageCustody, Permission::ReplaceWorkspace] {
		let keys: Vec<_> = session::SUPPORTED
			.iter()
			.filter(|permission| **permission != missing && permission.prerequisite() != Some(missing))
			.map(|permission| permission.key())
			.collect();
		let limited = policy.value_for_kind(session::KIND, &keys, &[]).unwrap();
		manager
			.set_policy(
				manager.mutation_sequence().await.unwrap(),
				glowcap::loam::control_revision(host, control).await.unwrap(),
				limited,
			)
			.await
			.unwrap();
		assert!(
			acquisition.submit().await.is_err(),
			"result acquisition requires {missing:?}"
		);
		assert_eq!(workspace.snapshot().await.unwrap().revision, snapshot.revision);
	}
	manager
		.set_policy(
			manager.mutation_sequence().await.unwrap(),
			glowcap::loam::control_revision(host, control).await.unwrap(),
			full,
		)
		.await
		.unwrap();
	refuse.set(true);
	assert!(acquisition.submit().await.is_err());
	let rolled_back = workspace.snapshot().await.unwrap();
	assert_eq!(rolled_back.revision, snapshot.revision);
	assert_ne!(rolled_back.intent, intent, "staged selection rolls back with custody");
	refuse.set(false);
	acquisition.submit().await.unwrap();
	let after = workspace.snapshot().await.unwrap();
	assert_eq!(after.intent, intent);
	// Record revisions are Store commit numbers. Grant and receipt commits may
	// leave gaps even when this graph changes in one atomic replacement.
	assert!(after.revision > snapshot.revision);
	acquisition.submit().await.unwrap();
	assert_eq!(workspace.snapshot().await.unwrap().revision, after.revision);
	let restored = owner
		.restore_custody(&[field(custody::Role::SessionAccess, 9)])
		.await
		.unwrap();
	assert_eq!(
		restored,
		vec![source.clone()],
		"worker restores the exact initiating grant"
	);
	drop(restored);
	// Comparing ordinary ingress with the acquired source proves exact held
	// identity, including its grant. Equal policy or a private root cannot pass.
	host.send(
		source,
		"import",
		&rooms_glowcap::client::workspace::Import {
			coordinate: field(custody::Role::SessionAccess, 9),
			reference: source.clone(),
			uri: None,
		}
		.into_arguments()
		.unwrap(),
	)
	.await
	.unwrap();
	assert_eq!(workspace.snapshot().await.unwrap().revision, after.revision);
	// Ordinary import proves the selected seat is the same dependent facet,
	// rather than a new wrapper or a raw upstream capability.
	host.send(
		source,
		"import",
		&rooms_glowcap::client::workspace::Import {
			coordinate: field(custody::Role::RoomSeat, 9),
			reference: actual[0].clone(),
			uri: None,
		}
		.into_arguments()
		.unwrap(),
	)
	.await
	.unwrap();
	assert_eq!(workspace.snapshot().await.unwrap().revision, after.revision);
	let changed = workspace
		.prepare_command(
			"intervening-result-edit",
			after.revision,
			"setStanding",
			&["changed".into()],
		)
		.await
		.unwrap();
	assert_eq!(
		changed.submit().await.unwrap(),
		rooms_glowcap::client::workspace::EffectStatus::Committed
	);
	let intervening = workspace.snapshot().await.unwrap();
	acquisition.submit().await.unwrap();
	assert_eq!(
		workspace.snapshot().await.unwrap().intent,
		intervening.intent,
		"adopted replay cannot erase intervening intent"
	);
	let current = workspace.snapshot().await.unwrap();
	let releases: Vec<_> = mappings
		.iter()
		.map(|mapping| mapping.destination)
		.chain([field(custody::Role::SessionAccess, 9)])
		.collect();
	let retirement = workspace
		.prepare_acquisition(current.revision, Vec::new(), &releases, &original)
		.unwrap();
	retirement.submit().await.unwrap();
	let retired = workspace.snapshot().await.unwrap();
	assert_eq!(retired.intent, original);
	retirement.submit().await.unwrap();
	assert_eq!(workspace.snapshot().await.unwrap().revision, retired.revision);
	let reacquire = command
		.prepare_result_acquisition_with_source(retired.revision, &mappings, &[], &intent, Some(source_key))
		.unwrap();
	reacquire.submit().await.unwrap();
	assert_eq!(
		workspace.snapshot().await.unwrap().revision,
		retired.revision,
		"completed adoption cannot resurrect retired custody"
	);
}
