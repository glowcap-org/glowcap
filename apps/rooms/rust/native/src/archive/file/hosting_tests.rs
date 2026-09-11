use super::tests::{record, Temp};
use super::*;
use crate::{archive::Archive, client::Deadline};
use glowcap::{tcp, Argument, ConnectOptions, Host, ListenerIdentity, PendingWork, Runtime, RuntimeConfig};
use rooms_application::archive::{Access, Facet};
use rooms_glowcap::{
	archive as wire,
	client::{archive::Archive as ClientArchive, Client},
};
use std::{rc::Rc, time::Duration};
#[tokio::test]
async fn hosted_journal_acknowledges_disk_and_keeps_the_executor_available() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(15), scenario())
				.await
				.expect("hosted disk deadline")
		})
		.await;
}
async fn scenario() {
	let temp = Temp::new();
	let backend = FileArchive::open(&temp.0, Options::default()).await.unwrap();
	let stored = backend.store.clone();
	let clear_store = stored.clone();
	let (locked, ready) = std::sync::mpsc::channel();
	let (release, wait) = std::sync::mpsc::channel();
	let disk = std::thread::spawn(move || {
		let _held = stored.lock().unwrap();
		locked.send(()).unwrap();
		let _ = wait.recv();
	});
	ready.recv().unwrap();
	let (owner, worker) = Archive::new(crate::client::Deadline, backend);
	let worker = tokio::task::spawn_local(worker.run());
	let host = Host::from_seed([199; 32]).unwrap();
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
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let locator = server.locator().unwrap();
	let (connected, accepted) =
		tokio::try_join!(runtime.connect(&locator, ConnectOptions::default()), server.accept()).unwrap();
	let accepted = Rc::new(accepted.with_gc());
	let service = accepted.clone();
	let serving = tokio::task::spawn_local(async move { service.serve().await });
	let root = owner
		.receiver()
		.spawn(&accepted, Facet::new(Filter::default(), Access::ReadWrite).unwrap())
		.unwrap();
	let target = root.clone();
	let publication = accepted
		.publish("archive", move |_, _| Ok(target.clone().into()))
		.unwrap();
	let ping = accepted.publish("ping", |_, _| Ok("pong".into())).unwrap();
	let client = Client::new(connected, Deadline);
	let reference = client
		.session()
		.send(&client.session().fetch("archive").await.unwrap(), "root", &[])
		.await
		.unwrap();
	let Argument::Reference(reference) = reference else {
		panic!("archive reference")
	};
	let archive = ClientArchive::new(client.clone(), reference.clone());
	let pending = client.session().send(
		&reference,
		"put",
		&[wire::record_row(&record("one", "durable".into(), 1))],
	);
	let pong = client
		.session()
		.send(&client.session().fetch("ping").await.unwrap(), "ping", &[])
		.await
		.unwrap();
	assert_eq!(pong.as_str(), Some("pong"));
	assert_eq!(owner.usage().requests, 1);
	release.send(()).unwrap();
	disk.join().unwrap();
	assert!(matches!(pending.await.unwrap(), Argument::Integer(1)));
	let on_disk = disk::recover(&std::fs::read(temp.file()).unwrap(), 5000, 512, disk::MAX_FILE_BYTES).unwrap();
	assert_eq!(on_disk.index.revision(), 1);
	assert_eq!(archive.read_all(&Filter::default()).await.unwrap().len(), 1);
	let final_revision = super::hosted_blobs::run(&archive, &client).await;
	assert!(client.session().send(&reference, "clear", &[]).await.is_err());
	let (held, ready) = std::sync::mpsc::channel();
	let (release, wait) = std::sync::mpsc::channel();
	let disk = std::thread::spawn(move || {
		let _held = clear_store.lock().unwrap();
		held.send(()).unwrap();
		let _ = wait.recv();
	});
	ready.recv().unwrap();
	assert!(tokio::time::timeout(Duration::from_millis(10), owner.clear())
		.await
		.is_err());
	assert_eq!(owner.usage().requests, 1);
	let read = client.session().send(
		&reference,
		"read",
		&[
			wire::filter_row(&Filter::default()).unwrap(),
			0_i64.into(),
			128_i64.into(),
		],
	);
	release.send(()).unwrap();
	disk.join().unwrap();
	let answer = read.await.unwrap();
	let page =
		rooms_application::archive::protocol::page(&rooms_glowcap::Value(&answer), &Filter::default(), 0, 128).unwrap();
	assert!(page.records.is_empty());
	assert_eq!(page.next, final_revision);
	let report = owner.close().await.unwrap();
	assert!(report.completed >= 12);
	assert_eq!(report.reply_failures, 1);
	assert_eq!(worker.await.unwrap(), report);
	drop((archive, reference, root, owner));
	accepted.release(publication).unwrap();
	accepted.release(ping).unwrap();
	client.session().close(PendingWork::Cancel).await.unwrap();
	drop(client);
	accepted.close(PendingWork::Cancel).await.unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
	server.close().await.unwrap();
	host.close(PendingWork::Cancel).await.unwrap();
	serving.await.unwrap().unwrap();
	let mut restored = FileArchive::open(&temp.0, Options::default()).await.unwrap();
	assert!(restored
		.read(&Filter::default(), 0, 128)
		.await
		.unwrap()
		.records
		.is_empty());
	assert_eq!(
		restored.read(&Filter::default(), 0, 128).await.unwrap().next,
		final_revision
	);
}
