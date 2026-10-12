//! Assigned names are output. Only a user nickname edit restarts registration.
use super::*;
use rooms_application::directory::registration::NicknameAllocation;
use rooms_glowcap::client::workspace::Workspace;

pub(super) async fn run(
	host: &Host,
	owner: &managed::Session<Platform>,
	source: &Ref,
	original: &Intent,
	count: &Cell<usize>,
) {
	let workspace = Workspace::local(host.clone(), Platform::default(), source.clone());
	let original_inbox = session::workspace::InboxSelection::directory(&original.directories.as_slice()[0])
		.unwrap()
		.coordinate();
	let original_reference = owner.restore_custody(&[original_inbox]).await.unwrap().remove(0);
	let mut intent = original.clone();
	intent.directories.as_mut_slice()[0].nick_allocation = NicknameAllocation::Automatic;
	owner.replace_workspace(&intent).await.unwrap();
	let prior = count.get();
	let mut memberships = managed::Memberships::default();
	let mut entropy = realization::Entropy::seeded(500);
	let report = memberships
		.reconcile(owner, &intent, "ocapn://member.id", &mut entropy, |_| {
			Box::new(|_| Ok(Argument::Void))
		})
		.await;
	assert!(
		report.failures.is_empty(),
		"automatic registration: {:?}",
		report.failures
	);
	assert_eq!(report.ready, 1);
	let installed = workspace.snapshot().await.unwrap().intent;
	let row = &installed.directories.as_slice()[0];
	assert_eq!(row.nick.text().as_str(), Some("self"));
	assert_eq!(row.assigned_nick.as_ref().unwrap().text().as_str(), Some("self2"));
	let callback = owner
		.restore_custody(&[session::workspace::InboxSelection::directory(row).unwrap().coordinate()])
		.await
		.unwrap()
		.remove(0);
	host.send(&callback, "notify", &[]).await.unwrap();
	let report = memberships
		.reconcile(owner, &installed, "ocapn://member.id", &mut entropy, |_| {
			panic!("assigned nickname cannot restart registration")
		})
		.await;
	assert!(report.failures.is_empty());
	assert_eq!(count.get(), prior + 1);
	let mut changed = installed;
	let row = &mut changed.directories.as_mut_slice()[0];
	row.nick = rooms_application::fields::Text::new("replacement".into()).unwrap();
	row.nick_allocation = NicknameAllocation::Exact;
	owner.replace_workspace(&changed).await.unwrap();
	assert!(
		host.send(&callback, "notify", &[]).await.is_err(),
		"nickname edits fence the old callback before reconciliation"
	);
	let report = memberships
		.reconcile(owner, &changed, "ocapn://member.id", &mut entropy, |_| {
			Box::new(|_| Ok(Argument::Void))
		})
		.await;
	assert!(report.failures.is_empty(), "nickname edit: {:?}", report.failures);
	assert_eq!(report.ready, 1);
	assert_eq!(
		count.get(),
		prior + 2,
		"a requested nickname edit registers exactly once"
	);
	assert!(host.send(&callback, "notify", &[]).await.is_err());
	let installed = workspace.snapshot().await.unwrap();
	assert_eq!(
		installed.intent.directories.as_slice()[0]
			.assigned_nick
			.as_ref()
			.unwrap()
			.text()
			.as_str(),
		Some("replacement")
	);
	let callback = owner
		.restore_custody(&[
			session::workspace::InboxSelection::directory(&installed.intent.directories.as_slice()[0])
				.unwrap()
				.coordinate(),
		])
		.await
		.unwrap()
		.remove(0);
	workspace
		.prepare_command(
			"release-registration",
			installed.revision,
			"chooseDirectoryNickname",
			&["directory".into(), "".into(), "exact".into()],
		)
		.await
		.unwrap()
		.submit()
		.await
		.unwrap();
	let unnamed = workspace.snapshot().await.unwrap().intent;
	assert!(host.send(&callback, "notify", &[]).await.is_err());
	for _ in 0..2 {
		let report = memberships
			.reconcile(owner, &unnamed, "ocapn://member.id", &mut entropy, |_| {
				panic!("browsing without a nickname must not register a member")
			})
			.await;
		assert!(report.failures.is_empty());
		assert_eq!(report.ready, 0);
		assert_eq!(count.get(), prior + 2, "releasing a nickname does not register again");
	}
	memberships.close().await.unwrap();
	let installed = workspace.snapshot().await.unwrap();
	let releases = installed
		.intent
		.coordinates()
		.filter(|field| !original.coordinates().any(|original| original == *field))
		.collect::<Vec<_>>();
	workspace
		.prepare_acquisition(
			installed.revision,
			vec![rooms_glowcap::client::workspace::Import {
				coordinate: original_inbox,
				reference: original_reference,
				uri: None,
			}],
			&releases,
			original,
		)
		.unwrap()
		.submit()
		.await
		.unwrap();
}
