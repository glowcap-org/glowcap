//! Discovery uses the saved original source and never exposes directory powers.
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
	let rooms = reader.list().await.unwrap();
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
	let (other, _) = owner.derive(terms, 0, ControlPowers::default()).await.unwrap();
	assert!(
		Workspace::local(host.clone(), Platform::default(), other)
			.directory_reader("directory")
			.await
			.is_err(),
		"equal reading permission cannot substitute for the saved original source"
	);
	let raw = host
		.send(source, "directory-reader", &["directory".into()])
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
	publication_results::lifecycle(host, control, "pause").await;
	assert!(reader.list().await.is_err());
	publication_results::lifecycle(host, control, "resume").await;
	assert_eq!(reader.list().await.unwrap().len(), 1);
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
	assert_eq!(reader.list().await.unwrap().len(), 1);
	assert!(
		workspace
			.directory_reader("directory")
			.await
			.unwrap()
			.list()
			.await
			.unwrap()
			.is_empty()
	);
	assert!(
		worker.directory_reader().await.is_err(),
		"a stale worker acquired replacement custody"
	);
	owner.replace_workspace(&original).await.unwrap();
	super::directory_ingress::run(host, owner, source, replacement).await;
}
