use super::{
	blob_tests::{line, Bytes},
	tests::Temp,
	*,
};
use crate::{archive::Archive, client::Deadline};
use glowcap::{tcp, Argument, ConnectOptions, Host, ListenerIdentity, PendingWork, Runtime, RuntimeConfig};
use rooms_application::archive::{
	shares::{Command, Share},
	Access,
};
use rooms_glowcap::client::{archive::Archive as ClientArchive, Client};
use std::{rc::Rc, time::Duration};
const ID: &str = "12345678-1234-4234-8234-123456789abc";
fn spec(id: &str) -> Share {
	Share::new(
		id.into(),
		"Garden".into(),
		Filter {
			directory: Some("directory".into()),
			..Default::default()
		},
	)
	.unwrap()
}
#[tokio::test]
async fn durable_share_revocation_reaches_held_descendants_and_queued_reads() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(20), scenario())
				.await
				.expect("archive share progress");
		})
		.await;
}
async fn scenario() {
	let temp = Temp::new();
	let mut backend = FileArchive::open(&temp.0, Options::default()).await.unwrap();
	let files = [Bytes::new(b"kept".to_vec())];
	backend.put_with_files(line("one", &files), &files).await.unwrap();
	backend.change_share(Command::Issue(spec(ID))).await.unwrap();
	let stored = backend.store.clone();
	let host = Host::from_seed([200; 32]).unwrap();
	let server = tcp::listen(
		"127.0.0.1",
		0,
		tcp::ListenOptions {
			identity: ListenerIdentity::Host(host.clone()),
			..Default::default()
		},
	)
	.await
	.unwrap();
	let locator = server.locator().unwrap();
	let (owner, mut worker) = Archive::new(crate::client::Deadline, backend);
	let occupied = host
		.publish_durable_with_entropy(spec(ID).entropy(&[23; 16]), || Box::new(|_, _| Ok("occupied".into())))
		.unwrap();
	assert!(worker.publish(host.clone(), [23; 16], locator.clone()).await.is_err());
	host.remove_durable(&occupied).unwrap();
	let root_link = worker.retry_publications().await.unwrap();
	let worker = tokio::task::spawn_local(worker.run());
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let (connected, accepted) =
		tokio::try_join!(runtime.connect(&locator, ConnectOptions::default()), server.accept()).unwrap();
	let accepted = Rc::new(accepted.with_gc());
	let service = accepted.clone();
	let serving = tokio::task::spawn_local(async move { service.serve().await });
	let client = Client::new(connected, Deadline);
	let root_ref = client.session().enliven(&root_link).await.unwrap();
	let root = ClientArchive::new(client.clone(), root_ref.clone());
	let listed = root.shares().await.unwrap();
	assert_eq!(listed.len(), 1);
	assert_eq!(listed[0].share, spec(ID));
	let link = root.share(&spec(ID)).await.unwrap();
	assert_eq!(listed[0].sturdyref, link);
	// Persistence precedes publication. A colliding live name must not roll
	// back its new durable spec, and an identical retry must publish it once.
	let second = Share::new(
		"12345678-1234-4234-8234-123456789abd".into(),
		"Other directory".into(),
		Filter {
			directory: Some("other".into()),
			..Default::default()
		},
	)
	.unwrap();
	let occupied = host
		.publish_durable_with_entropy(second.entropy(&[23; 16]), || Box::new(|_, _| Ok("occupied".into())))
		.unwrap();
	assert!(root.share(&second).await.is_err());
	let ledger = rooms_application::archive::shares::Ledger::restore(
		&std::fs::read(temp.0.join(rooms_application::archive::shares::FILE)).unwrap(),
	)
	.unwrap();
	assert!(ledger.get(second.id()).unwrap().is_some());
	host.remove_durable(&occupied).unwrap();
	let second_link = root.share(&second).await.unwrap();
	let second_view = ClientArchive::new(client.clone(), client.session().enliven(&second_link).await.unwrap());
	assert!(second_view.read_all(&Filter::default()).await.unwrap().is_empty());
	let shared_ref = client.session().enliven(&link).await.unwrap();
	let shared = ClientArchive::new(client.clone(), shared_ref.clone());
	let child = shared.narrow(&Filter::default(), Access::Read).await.unwrap();
	let grandchild = child.narrow(&Filter::default(), Access::Read).await.unwrap();
	assert!(shared.narrow(&Filter::default(), Access::ReadWrite).await.is_err());
	assert!(shared.share(&spec(ID)).await.is_err());
	let same_scope_root = root.narrow(&Filter::default(), Access::ReadWrite).await.unwrap();
	assert!(same_scope_root.share(&spec(ID)).await.is_err());
	assert!(same_scope_root.shares().await.is_err());
	for _ in 0..253 {
		shared.narrow(&Filter::default(), Access::Read).await.unwrap();
	}
	assert!(shared.narrow(&Filter::default(), Access::Read).await.is_err());
	let other_runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let (other, accepted_other) = tokio::try_join!(
		other_runtime.connect(&locator, ConnectOptions::default()),
		server.accept()
	)
	.unwrap();
	let other_service = tokio::task::spawn_local(async move { accepted_other.with_gc().serve().await });
	let other = Client::new(other, Deadline);
	let other_share = ClientArchive::new(other.clone(), other.session().enliven(&link).await.unwrap());
	let other_child = other_share.narrow(&Filter::default(), Access::Read).await.unwrap();
	let page = grandchild.read_all(&Filter::default()).await.unwrap();
	let record = &page[0].record;
	let attachment = grandchild.attachment(record, 0).await.unwrap();
	let digest = rooms_application::archive::blobs::files(record).unwrap()[0]
		.blob()
		.unwrap();
	let by_digest = child.blob(digest).await.unwrap();
	assert_eq!(attachment.read(0, 4).await.unwrap(), b"kept");
	assert_eq!(by_digest.read(0, 4).await.unwrap(), b"kept");
	// Hold disk while revoke and then a read are admitted. The actor executor
	// still responds; the queued read must recheck committed revocation.
	let (held, ready) = std::sync::mpsc::channel();
	let (release, wait) = std::sync::mpsc::channel();
	let lock = std::thread::spawn(move || {
		let _held = stored.lock().unwrap();
		held.send(()).unwrap();
		wait.recv().unwrap();
	});
	ready.recv().unwrap();
	let listing = client.session().send(&root_ref, "shares", &[]);
	let before = client
		.session()
		.send(attachment.reference(), "read", &[0_i64.into(), 4_i64.into()]);
	let revoke = client.session().send(&root_ref, "revokeShare", &[ID.into()]);
	let queued = client
		.session()
		.send(attachment.reference(), "read", &[0_i64.into(), 4_i64.into()]);
	let ping = accepted.publish("share-ping", |_, _| Ok("pong".into())).unwrap();
	assert_eq!(
		client
			.session()
			.send(&client.session().fetch("share-ping").await.unwrap(), "ping", &[])
			.await
			.unwrap()
			.as_str(),
		Some("pong")
	);
	assert_eq!(owner.usage().requests, 4);
	// Listing on a busy disk must not pause healthy on-turn attenuation.
	other_share.narrow(&Filter::default(), Access::Read).await.unwrap();
	release.send(()).unwrap();
	lock.join().unwrap();
	assert!(matches!(listing.await.unwrap(), Argument::List(_)));
	assert!(matches!(before.await.unwrap(), Argument::Bytes(bytes) if bytes == b"kept"));
	assert!(matches!(revoke.await.unwrap(), Argument::Boolean(true)));
	assert!(queued.await.is_err());
	assert!(shared.read_all(&Filter::default()).await.is_err());
	assert!(child.read_all(&Filter::default()).await.is_err());
	assert!(grandchild.read_all(&Filter::default()).await.is_err());
	assert!(attachment.read(0, 4).await.is_err());
	assert!(by_digest.read(0, 4).await.is_err());
	assert!(other_child.read_all(&Filter::default()).await.is_err());
	assert!(!root.revoke_share(ID).await.unwrap());
	assert!(root.share(&spec(ID)).await.is_err());
	assert_eq!(root.shares().await.unwrap().len(), 1);
	assert!(second_view.read_all(&Filter::default()).await.unwrap().is_empty());
	assert!(root.revoke_share(second.id()).await.unwrap());
	assert_eq!(root.read_all(&Filter::default()).await.unwrap().len(), 1);
	let third = spec("12345678-1234-4234-8234-123456789abe");
	let third_link = root.share(&third).await.unwrap();
	let third_view = ClientArchive::new(client.clone(), client.session().enliven(&third_link).await.unwrap());
	let path = temp.0.join(rooms_application::archive::shares::FILE);
	let backup = temp.0.join("saved-shares");
	std::fs::rename(&path, &backup).unwrap();
	std::fs::create_dir(&path).unwrap();
	assert!(root.revoke_share(third.id()).await.is_err());
	assert!(third_view.narrow(&Filter::default(), Access::Read).await.is_err());
	std::fs::remove_dir(&path).unwrap();
	std::fs::rename(&backup, &path).unwrap();
	assert!(root.shares().await.is_err());
	let report = owner.close().await.unwrap();
	assert_eq!(report.publication_failures, 0);
	assert_eq!(worker.await.unwrap(), report);
	assert!(root.shares().await.is_err());
	accepted.release(ping).unwrap();
	other.session().close(PendingWork::Cancel).await.unwrap();
	assert!(other_service.await.unwrap().is_ok());
	drop((other_child, other_share, other));
	client.session().close(PendingWork::Cancel).await.unwrap();
	assert!(serving.await.unwrap().is_ok());
	drop((
		client,
		root,
		shared,
		child,
		grandchild,
		same_scope_root,
		attachment,
		by_digest,
		owner,
	));
	drop((root_ref, shared_ref, accepted));
	let mut backend = FileArchive::open(&temp.0, Options::default()).await.unwrap();
	assert_eq!(backend.active_shares().await.unwrap(), vec![third]);
	assert!(backend.change_share(Command::Issue(spec(ID))).await.is_err());
	let (restored_owner, mut restored_worker) = Archive::new(crate::client::Deadline, backend);
	assert_eq!(
		restored_worker.publish(host.clone(), [23; 16], locator).await.unwrap(),
		root_link
	);
	// Abandoning a configured worker also releases its owned lookup names.
	drop(restored_worker);
	let released = host
		.publish_durable_with_entropy([23; 16], || Box::new(|_, _| Ok(Argument::Void)))
		.unwrap();
	host.remove_durable(&released).unwrap();
	drop(restored_owner);
}
