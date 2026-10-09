//! Result import preserves exact receipt custody through the original source.
use super::*;
use rooms_application::content::permissions::Permission;

fn coordinate(role: custody::Role, slot: u64) -> custody::Coordinate {
	custody::Coordinate {
		role,
		key: custody::FieldKey::new(NonZeroU64::new(slot).unwrap(), NonZeroU64::new(1).unwrap()),
	}
}
async fn snapshot(host: &Host, source: &Ref) -> Argument {
	host.send(source, "snapshot", &[]).await.unwrap()
}
pub(super) async fn membership(
	host: &Host,
	owner: &managed::Session<Platform>,
	sources: (&Ref, &Ref, &Ref),
	policy: (&loam::Policy, loam::PolicyValue),
	canonical: &str,
	actual: &[Ref],
	audit: (&Cell<bool>, &Ref),
) {
	let (root, source, control) = sources;
	let (policy, terms) = policy;
	let (refuse, different) = audit;
	let result = coordinate(custody::Role::RoomSeat, 1);
	let destination = coordinate(custody::Role::RoomSeat, 7);
	let (other, _) = owner.derive(terms, 1, ControlPowers::default()).await.unwrap();
	let before = snapshot(host, source).await;
	for wrong in [root, &other] {
		assert!(
			owner
				.import_result(wrong, "joined", canonical, result, destination)
				.await
				.is_err(),
			"equal terms and private root cannot substitute for the original source"
		);
	}
	for (id, intent, result, destination) in [
		("missing", canonical.to_owned(), result, destination),
		("joined", canonical.replace("member", "other"), result, destination),
		(
			"joined",
			canonical.to_owned(),
			coordinate(custody::Role::RoomSeat, 99),
			destination,
		),
		(
			"joined",
			canonical.to_owned(),
			result,
			coordinate(custody::Role::RoomTopic, 7),
		),
	] {
		assert!(
			owner
				.import_result(source, id, &intent, result, destination)
				.await
				.is_err()
		);
	}
	assert!(
		host.send(
			source,
			"import-result",
			&[
				"joined".into(),
				canonical.into(),
				serde_json::to_string(&(result.role, result.key)).unwrap().into(),
				serde_json::to_string(&destination).unwrap().into(),
			]
		)
		.await
		.is_err(),
		"coordinates require objects"
	);
	assert_eq!(snapshot(host, source).await, before);
	let interaction = policy
		.value_for_kind(
			session::KIND,
			&[Permission::ObserveWorkspace.key(), Permission::InteractWorkspace.key()],
			&[],
		)
		.unwrap();
	host.send(
		control,
		"mutate",
		&interaction.set_policy_arguments(3, glowcap::loam::control_revision(host, control).await.unwrap()),
	)
	.await
	.unwrap();
	assert!(
		owner
			.import_result(source, "joined", canonical, result, destination)
			.await
			.is_err(),
		"result delivery admission does not imply ManageCustody"
	);
	host.send(
		control,
		"mutate",
		&terms.set_policy_arguments(4, glowcap::loam::control_revision(host, control).await.unwrap()),
	)
	.await
	.unwrap();
	refuse.set(true);
	assert!(
		owner
			.import_result(source, "joined", canonical, result, destination)
			.await
			.is_err()
	);
	assert_eq!(
		snapshot(host, source).await,
		before,
		"staged result import rolls back atomically"
	);
	refuse.set(false);
	owner.import(destination, different.clone(), None).await.unwrap();
	let occupied = snapshot(host, source).await;
	assert!(
		owner
			.import_result(source, "joined", canonical, result, destination)
			.await
			.is_err()
	);
	assert_eq!(
		snapshot(host, source).await,
		occupied,
		"occupied authority cannot be replaced"
	);
	let stale = custody::Coordinate {
		role: destination.role,
		key: custody::FieldKey::new(destination.key.slot(), NonZeroU64::new(2).unwrap()),
	};
	assert!(
		owner
			.import_result(source, "joined", canonical, result, stale)
			.await
			.is_err()
	);
	mutate(
		host,
		root,
		"release",
		&[
			serde_json::to_string(&destination).unwrap().into(),
			snapshot(host, source).await.as_list().unwrap()[1].clone(),
		],
	)
	.await
	.unwrap();
	owner
		.import_result(source, "joined", canonical, result, destination)
		.await
		.unwrap();
	let committed = snapshot(host, source).await;
	owner
		.import_result(source, "joined", canonical, result, destination)
		.await
		.unwrap();
	assert_eq!(snapshot(host, source).await, committed, "import retry is a no-op");
	// Equality with the existing disclosed facet proves identity survived the
	// graph transfer. Substituting its raw target would remove the session gate.
	owner.import(destination, actual[0].clone(), None).await.unwrap();
	assert_eq!(snapshot(host, source).await, committed);
	for role in [custody::Role::RoomTopic, custody::Role::RoomFiles] {
		let field = coordinate(role, 1);
		let destination = coordinate(role, 7);
		let exists = host
			.send(source, "effect-result", &["joined".into(), canonical.into()])
			.await
			.unwrap()
			.as_list()
			.unwrap()[1]
			.as_list()
			.unwrap()
			.iter()
			.any(|value| {
				custody::Coordinate::decode(value.as_list().unwrap()[0].as_str().unwrap())
					.unwrap()
					.role == role
			});
		assert_eq!(
			owner
				.import_result(source, "joined", canonical, field, destination)
				.await
				.is_ok(),
			exists
		);
	}
	host.send(
		control,
		"pause",
		&[Argument::Bytes(
			glowcap::loam::control_revision(host, control)
				.await
				.unwrap()
				.to_be_bytes()
				.to_vec(),
		)],
	)
	.await
	.unwrap();
	assert!(
		owner
			.import_result(source, "joined", canonical, result, destination)
			.await
			.is_err()
	);
	host.send(
		control,
		"resume",
		&[Argument::Bytes(
			glowcap::loam::control_revision(host, control)
				.await
				.unwrap()
				.to_be_bytes()
				.to_vec(),
		)],
	)
	.await
	.unwrap();
	owner
		.import_result(source, "joined", canonical, result, destination)
		.await
		.unwrap();
	super::result_acquisition::membership(host, owner, source, canonical, actual, refuse, (control, policy, terms))
		.await;
}
