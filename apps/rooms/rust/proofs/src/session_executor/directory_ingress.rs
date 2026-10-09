//! A remote workspace reflects its exact local endpoint through atomic ingress.
use super::*;
use rooms_glowcap::client::{
	Client,
	workspace::{DirectoryImport, Workspace},
};

pub(super) async fn run(host: &Host, owner: &managed::Session<Platform>, source: &Ref, directory: &Ref) {
	let local = Workspace::local(host.clone(), Platform::default(), source.clone());
	let original = local.snapshot().await.unwrap();
	host.publish("directory-ingress", {
		let source = source.clone();
		let directory = directory.clone();
		move || Box::new(move |_, _| Ok(Argument::List(vec![source.clone().into(), directory.clone().into()])))
	})
	.unwrap();
	let peer = Host::from_seed([181; 32]).unwrap();
	let locator = glowcap::Locator::bare("tcp", "127.0.0.1:9198");
	let (left, right) = tokio::io::duplex(4096);
	let (client, server) = tokio::join!(
		glowcap::Session::dial_over(&peer, &locator, left, Some(std::time::Duration::from_secs(2))),
		glowcap::Session::accept_over(
			host,
			"tcp",
			"127.0.0.1:9198",
			"127.0.0.1:9197",
			right,
			Some(std::time::Duration::from_secs(2))
		)
	);
	let (client, server) = (client.unwrap(), server.unwrap());
	let gateway = client.fetch("directory-ingress").await.unwrap();
	let pair = client.send(&gateway, "get", &[]).await.unwrap();
	let Some([Argument::Reference(reflected), Argument::Reference(target)]) = pair.as_list() else {
		panic!("ingress capabilities")
	};
	let remote = Workspace::new(Client::new(client, Platform::default()), reflected.clone());
	let snapshot = remote.snapshot().await.unwrap();
	let mut row = snapshot.intent.directories.as_slice()[0].clone();
	row.id = rooms_application::fields::Text::new("acquired".into()).unwrap();
	row.access = fresh(84);
	row.source = Some(fresh(84));
	row.name = None;
	row.inbox = None;
	row.home = true;
	let preparing = |revision, intent: &Intent| {
		remote.prepare_directory(
			revision,
			DirectoryImport {
				row: row.clone(),
				reference: target.clone(),
				uri: None,
			},
			intent,
		)
	};
	let stale = preparing(snapshot.revision, &snapshot.intent).unwrap();
	assert!(
		stale.reprepare().await.is_err(),
		"unsubmitted acquisition was re-prepared"
	);
	let mut changed = snapshot.intent.clone();
	changed.standing = rooms_application::fields::Text::new("intervening".into()).unwrap();
	owner.replace_workspace(&changed).await.unwrap();
	assert!(stale.submit().await.is_err(), "ingress overwrote intervening intent");
	assert_eq!(
		local.snapshot().await.unwrap().intent,
		changed,
		"failed acquisition partially installed its row"
	);
	{
		let mut replay = std::pin::pin!(stale.submit());
		let mut context = std::task::Context::from_waker(std::task::Waker::noop());
		assert!(std::future::Future::poll(replay.as_mut(), &mut context).is_pending());
	}
	assert!(
		stale.reprepare().await.is_err(),
		"interrupted replay reused old conflict proof"
	);
	assert!(matches!(
		stale.submit().await,
		Err(rooms_glowcap::client::Error::WorkspaceConflict)
	));
	let acquisition = stale.reprepare().await.unwrap();
	assert_eq!(
		acquisition.source(),
		reflected,
		"preparation substituted a different grant"
	);
	acquisition.submit().await.unwrap();
	acquisition.submit().await.unwrap();
	let installed = local.snapshot().await.unwrap();
	assert_eq!(
		installed
			.intent
			.directories
			.as_slice()
			.iter()
			.filter(|row| row.home)
			.count(),
		1
	);
	let acquired = installed.intent.directories.as_slice().last().unwrap();
	assert_eq!(acquired.id, row.id);
	assert_eq!(acquired.access, row.access);
	assert_eq!(acquired.source, row.source);
	assert_eq!(installed.intent.standing, changed.standing);
	assert!(
		stale.reprepare().await.is_err(),
		"re-preparation replaced an installed directory"
	);
	let saved = owner
		.restore_custody(&[requests::coordinate(custody::Role::SessionAccess, 84)])
		.await
		.unwrap();
	assert_eq!(
		&saved[0], source,
		"remote ingress failed to preserve the exact local endpoint"
	);
	assert!(
		remote
			.directory_reader("acquired")
			.await
			.unwrap()
			.list()
			.await
			.unwrap()
			.is_empty()
	);
	assert!(
		preparing(installed.revision, &installed.intent).is_err(),
		"duplicate row refetched/replaced acquisition"
	);
	owner.replace_workspace(&original.intent).await.unwrap();
	host.unpublish("directory-ingress").unwrap();
	drop((acquisition, stale, remote, saved, pair, gateway, server));
	peer.close(PendingWork::Cancel).await.unwrap();
}
fn fresh<K>(slot: u64) -> custody::FieldKey<K> {
	custody::FieldKey::new(NonZeroU64::new(slot).unwrap(), NonZeroU64::new(1).unwrap())
}
