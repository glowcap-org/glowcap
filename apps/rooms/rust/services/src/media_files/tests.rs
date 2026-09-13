use super::*;
use crate::{
	archive::file::{FileArchive, Options},
	session_archive::{FileRecording, SessionArchive},
};
use glowcap::Session;
use glowcap::{Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig, tcp};
use rooms_application::files::FileDescription;
use rooms_application::files::sources::MAX_READS;
use rooms_application::{
	archive::{ConversationKind, Filter, recording::Message},
	files::CHUNK_BYTES,
	room::message::{ChangeKind, LineId},
};
use rooms_application::{files::sources::MAX_SOURCES, room::attachment::Attachment};
use rooms_glowcap::client::Client;
use rooms_glowcap::client::{
	direct::{self, Direct},
	sources::{Source, Sources},
};
use std::time::Duration;
use std::{cell::RefCell, rc::Rc};
use tokio::sync::mpsc;

pub(super) fn description(name: &str, size: usize) -> FileDescription {
	FileDescription::new(name.into(), "application/octet-stream".into(), size as u64, 0, 0).unwrap()
}
#[tokio::test]
async fn incoming_materialization_is_shared_by_archive_and_views_through_expiration() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(20), scenario()).await.unwrap();
		})
		.await;
}
async fn scenario() {
	let runtime = Rc::new(
		Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
			.await
			.unwrap(),
	);
	let server = tcp::listen("127.0.0.1", 0, Default::default()).await.unwrap();
	let locator = server.locator().unwrap();
	let (caller, peer) = tokio::join!(runtime.connect(&locator, ConnectOptions::default()), server.accept());
	let peer = Rc::new(peer.unwrap().with_gc());
	let service = peer.clone();
	let serving = tokio::task::spawn_local(async move { service.serve().await });
	let client = Client::new(caller.unwrap(), HostPlatform);
	let (tx, mut delivered) = mpsc::channel(1);
	let root = peer
		.publish(
			"dm",
			direct::receiver(move |notice, session| {
				let rooms_application::direct::Notice::Message { attachments, .. } = notice else {
					return Err("message".into());
				};
				tx.try_send((session, attachments)).unwrap();
				Ok(Argument::Void)
			}),
		)
		.unwrap();
	let direct = Direct::adopt(
		client.clone(),
		client.session().fetch("dm").await.unwrap(),
		rooms_application::directory::registration::Id::parse("11111111-1111-4111-8111-111111111111").unwrap(),
	);
	let sources = Sources::new(HostPlatform);
	let size = CHUNK_BYTES + 1;
	direct
		.send_files(
			"one read",
			&sources,
			vec![Source::bytes(description("file", size), vec![9; size]).unwrap()],
		)
		.await
		.unwrap();
	let (session, mut attachments) = delivered.recv().await.unwrap();
	let attachment = attachments.pop().unwrap();
	let mut owner = MediaFiles::default();
	let file = owner.receive(&session, attachment.clone()).unwrap();
	let mut renamed = attachment;
	renamed.description = description("renamed", size);
	let duplicate = owner.receive(&session, renamed).unwrap();
	assert_eq!(owner.usage().files, 1);
	let first = file.materialize();
	let second = duplicate.materialize();
	let path = std::env::temp_dir().join(format!("rooms-received-{}", std::process::id()));
	let (archive, worker) = SessionArchive::new(
		rooms_platform::HostPlatform,
		runtime.clone(),
		FileArchive::open(&path, Options::default()).await.unwrap(),
	);
	let recording = archive
		.record_files(
			&"receiver".into(),
			&Message {
				keep: true,
				generation: Some(&"generation".into()),
				kind: ConversationKind::Direct,
				directory: &"directory".into(),
				conversation: &"direct".into(),
				nick: "alice",
				from: "bob",
				text: "one read",
				previews: &Default::default(),
				system: false,
				line: LineId::new(1),
				change: ChangeKind::Said,
				at: 1,
			},
			vec![file.clone()],
		)
		.unwrap()
		.unwrap();
	owner.expire(&file);
	assert!(file.read(0, 1).await.is_err());
	let (first, second) = tokio::join!(first, second);
	let (first, second) = (first.unwrap(), second.unwrap());
	assert_eq!(second.description().name(), "renamed");
	assert_eq!(sources.usage().bytes, 0, "the sender grants exactly one complete read");
	assert_eq!(first.read((CHUNK_BYTES - 1) as u64, 2).unwrap(), [9, 9]);
	let a = crate::archive::Source::read(&first, 0, CHUNK_BYTES).await.unwrap();
	let b = crate::archive::Source::read(&second, 0, CHUNK_BYTES).await.unwrap();
	assert_eq!(a.as_ref().as_ptr(), b.as_ref().as_ptr());
	drop((a, b));
	let worker = tokio::task::spawn_local(worker.run());
	assert_eq!(recording.completion.wait().await.unwrap().files, FileRecording::Stored);
	let rows = archive.read(Filter::default()).unwrap().wait().await.unwrap();
	assert_eq!(rows[0].blob(0).await.unwrap().unwrap().read(0, 1).await.unwrap(), [9]);
	drop(rows);
	archive.close().await.unwrap();
	worker.await.unwrap();
	drop(archive);
	owner.close().await.unwrap();
	assert_eq!(
		owner.usage().bytes,
		size,
		"materialized leases retain their allocation charge"
	);
	drop((first, second));
	assert_eq!(owner.usage(), Usage::default());
	std::fs::remove_dir_all(path).unwrap();
	pressure(client.session()).await;
	super::batch_tests::run(client.session()).await;
	pending_lifetime(client.session(), false).await;
	pending_lifetime(client.session(), true).await;
	peer.release(root).unwrap();
	drop((direct, file, duplicate, session, sources));
	assert!(client.session().is_open());
	client.session().close(PendingWork::Cancel).await.unwrap();
	peer.close(PendingWork::Cancel).await.unwrap();
	serving.await.unwrap().unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
}
async fn pressure(session: &Session) {
	for (count, size) in [(MAX_READS, 1), (4, rooms_application::files::MAX_FILE_BYTES)] {
		let mut owner = MediaFiles::default();
		let answers = Rc::new(RefCell::new(Vec::new()));
		let mut files = Vec::new();
		let mut roots = Vec::new();
		for n in 0..=count {
			let answers = answers.clone();
			let root = session
				.spawn_owned(move |_, _| {
					answers.borrow_mut().push(
						glowcap::current_session()
							.unwrap()
							.unwrap()
							.host()
							.defer_turn()
							.unwrap(),
					);
					Ok(Argument::Void)
				})
				.unwrap();
			let admitted = owner.receive(
				session,
				Attachment {
					description: description(&n.to_string(), size),
					blob: root.clone(),
				},
			);
			if n == count {
				assert!(admitted.is_err());
			} else {
				files.push(admitted.unwrap());
			}
			roots.push(root);
		}
		while answers.borrow().len() != count {
			tokio::task::yield_now().await;
		}
		for file in &files {
			owner.expire(file);
		}
		assert_eq!(
			owner.usage(),
			Usage {
				active: count,
				files: count,
				bytes: count * size
			}
		);
		for mut answer in answers.borrow_mut().drain(..) {
			answer.break_with("source refused").unwrap();
		}
		while owner.usage().active != 0 {
			tokio::task::yield_now().await;
		}
		assert_eq!(owner.usage(), Usage::default());
		owner.close().await.unwrap();
		for root in roots {
			session.release(root).unwrap();
		}
	}
	let mut owner = MediaFiles::default();
	let mut leases = Vec::new();
	for n in 0..=MAX_SOURCES {
		let root = session.spawn_owned(|_, _| panic!("empty files need no read")).unwrap();
		let admitted = owner.receive(
			session,
			Attachment {
				description: description(&n.to_string(), 0),
				blob: root.clone(),
			},
		);
		if n == MAX_SOURCES {
			assert!(admitted.is_err());
		} else {
			leases.push(admitted.unwrap().materialize().await.unwrap());
		}
		session.release(root).unwrap();
	}
	assert_eq!(owner.usage().files, MAX_SOURCES);
	owner.close().await.unwrap();
	assert_eq!(owner.usage().files, MAX_SOURCES);
	drop(leases);
	assert_eq!(owner.usage(), Usage::default());
	let mut owner = MediaFiles::default();
	let mut oldest = None;
	for n in 0..=MAX_SOURCES {
		let root = session.spawn_owned(|_, _| panic!("empty file read")).unwrap();
		let file = owner
			.receive(
				session,
				Attachment {
					description: description(&n.to_string(), 0),
					blob: root.clone(),
				},
			)
			.unwrap();
		drop(file.materialize().await.unwrap());
		if n == 0 {
			oldest = Some(file);
		}
		session.release(root).unwrap();
	}
	assert!(
		oldest.unwrap().read(0, 1).await.is_err(),
		"pressure expires the oldest unpinned view"
	);
	assert_eq!(owner.usage().files, MAX_SOURCES);
	owner.close().await.unwrap();
	assert_eq!(owner.usage(), Usage::default());
}
async fn pending_lifetime(session: &Session, cancel: bool) {
	use std::{
		future::Future,
		task::{Context, Waker},
	};
	let answer = Rc::new(RefCell::new(None));
	let pending = answer.clone();
	let root = session
		.spawn_owned(move |_, _| {
			*pending.borrow_mut() = Some(
				glowcap::current_session()
					.unwrap()
					.unwrap()
					.host()
					.defer_turn()
					.unwrap(),
			);
			Ok(Argument::Void)
		})
		.unwrap();
	let mut owner = MediaFiles::default();
	let file = owner
		.receive(
			session,
			Attachment {
				description: description("pending", 1),
				blob: root.clone(),
			},
		)
		.unwrap();
	let materialized = file.materialize();
	while answer.borrow().is_none() {
		tokio::task::yield_now().await;
	}
	if cancel {
		let mut closing = Box::pin(owner.close());
		assert!(
			closing
				.as_mut()
				.poll(&mut Context::from_waker(Waker::noop()))
				.is_pending()
		);
		drop(closing);
		owner.close().await.unwrap();
		assert_eq!(owner.usage(), Usage::default());
		assert!(materialized.await.is_err());
		answer
			.borrow_mut()
			.take()
			.unwrap()
			.break_with("late source refusal")
			.unwrap();
	} else {
		owner.expire(&file);
		assert!(file.read(0, 1).await.is_err());
		assert_eq!(owner.usage().active, 1);
		answer
			.borrow_mut()
			.take()
			.unwrap()
			.fulfill(&Argument::Bytes(vec![7]))
			.unwrap();
		let retained = materialized.await.unwrap();
		assert_eq!(retained.read(0, 1).unwrap(), [7]);
		owner.close().await.unwrap();
		assert_eq!(owner.usage().bytes, 1);
		drop(retained);
		assert_eq!(owner.usage(), Usage::default());
	}
	assert!(session.is_open());
	session.release(root).unwrap();
}
