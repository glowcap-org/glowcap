//! Viewer reads use their own grant. Discovery workers keep the saved source.
use super::*;
use rooms_glowcap::client::workspace::Workspace;

pub(super) async fn run(
	host: &Host,
	owner: &managed::Session<Platform>,
	source: &Ref,
	control: &Ref,
	replacement: &Ref,
) {
	let workspace = Workspace::local(host.clone(), Platform::default(), source.clone());
	let original = workspace.snapshot().await.unwrap().intent;
	let worker = owner
		.directory_source(&original.directories.as_slice()[0])
		.await
		.unwrap();
	let reader = worker.directory_reader().await.unwrap();
	let rooms = reader.list(None).await.unwrap().rooms;
	assert_eq!(rooms.len(), 1);
	assert_eq!(rooms[0].name.text().as_str(), Some("room"));
	assert_eq!(reader.advertised_location().await.unwrap(), "ocapn://member.id");
	assert_eq!(
		reader.member_registration("peer").await.unwrap().as_str(),
		"00000000-0000-4000-8000-000000000001"
	);
	assert!(reader.member_registration("").await.is_err());
	let terms = rooms_glowcap::policy::descriptor()
		.unwrap()
		.value_for_kind(
			session::KIND,
			&[rooms_application::content::permissions::Permission::ObserveWorkspace.key()],
			&[],
		)
		.unwrap();
	let (other, other_control) = owner
		.derive(
			terms,
			0,
			ControlPowers {
				pause: true,
				resume: true,
				revoke: true,
				..Default::default()
			},
		)
		.await
		.unwrap();
	assert_ne!(&other, source);
	let viewer = Workspace::local(host.clone(), Platform::default(), other);
	let viewer_reader = viewer.directory_reader("directory").await.unwrap();
	let selection = rooms_application::content::session::workspace::DiscoverySelection::directory(
		&original.directories.as_slice()[0],
	)
	.unwrap();
	assert!(
		viewer.check_discovery(&selection).await.is_err(),
		"viewer reading does not authorize the original discovery worker"
	);
	assert_eq!(viewer_reader.named_rooms("room").await.unwrap().len(), 1);
	assert_eq!(
		viewer_reader.member_registration("peer").await.unwrap().as_str(),
		"00000000-0000-4000-8000-000000000001"
	);
	publication_results::lifecycle(host, &other_control, "pause").await;
	assert!(viewer.directory_reader("directory").await.is_err());
	assert!(viewer_reader.list(None).await.is_err());
	assert_eq!(
		reader.list(None).await.unwrap().rooms.len(),
		1,
		"viewer pause does not pause the directory worker"
	);
	publication_results::lifecycle(host, &other_control, "resume").await;
	assert_eq!(viewer_reader.list(None).await.unwrap().rooms.len(), 1);
	let denied = rooms_glowcap::policy::descriptor()
		.unwrap()
		.value_for_kind(session::KIND, &[], &[])
		.unwrap();
	let (denied, _) = owner.derive(denied, 0, ControlPowers::default()).await.unwrap();
	assert!(
		Workspace::local(host.clone(), Platform::default(), denied)
			.directory_reader("directory")
			.await
			.is_err(),
		"reading requires ObserveWorkspace"
	);
	for access in [source, viewer.reference()] {
		let raw = host
			.send(access, "directory-reader", &["directory".into()])
			.await
			.unwrap();
		let Argument::Reference(raw) = raw else {
			panic!("exact discovery facade");
		};
		for method in ["register", "open", "introduce", "signalOffer", "watchPublications"] {
			assert!(
				host.send(&raw, method, &[]).await.is_err(),
				"discovery exposed {method}"
			);
		}
	}
	publication_results::lifecycle(host, control, "pause").await;
	assert!(reader.list(None).await.is_err());
	publication_results::lifecycle(host, control, "resume").await;
	assert_eq!(reader.list(None).await.unwrap().rooms.len(), 1);
	// Replacement affects fresh acquisition. The retained reader keeps the
	// exact target originally selected; it must not discover another directory.
	owner
		.import(
			requests::coordinate(custody::Role::DirectoryAccess, 83),
			replacement.clone(),
			None,
		)
		.await
		.unwrap();
	let mut changed = original.clone();
	changed.directories.as_mut_slice()[0].access =
		custody::FieldKey::new(NonZeroU64::new(83).unwrap(), NonZeroU64::new(1).unwrap());
	owner.replace_workspace(&changed).await.unwrap();
	assert_eq!(reader.list(None).await.unwrap().rooms.len(), 1);
	assert_eq!(
		viewer_reader.list(None).await.unwrap().rooms.len(),
		1,
		"retained viewer reader keeps its original target"
	);
	assert!(
		workspace
			.directory_reader("directory")
			.await
			.unwrap()
			.list(None)
			.await
			.unwrap()
			.rooms
			.is_empty()
	);
	assert!(
		worker.directory_reader().await.is_err(),
		"a stale worker acquired replacement custody"
	);
	owner.replace_workspace(&original).await.unwrap();
	publication_results::lifecycle(host, &other_control, "revoke").await;
	assert!(viewer_reader.list(None).await.is_err());
	assert!(viewer.directory_reader("directory").await.is_err());
	super::directory_ingress::run(host, owner, source, replacement).await;
}
