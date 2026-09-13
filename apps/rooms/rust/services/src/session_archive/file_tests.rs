mod capture_tests;
use super::*;
use crate::archive::{
	Source,
	file::{FileArchive, Options},
	peer::{Config, Transport, run},
};
use glowcap::{ConnectOptions, PendingWork, RuntimeConfig, tcp};
use rooms_application::{
	archive::{Attachment, Body, ConversationKind, Coordinates, LineState},
	files::FileDescription,
};
use rooms_glowcap::client::{Client, archive::Archive};
use rooms_runtime::archive::session::MAX_STREAMS;
use std::{path::PathBuf, time::Duration};
use tokio::sync::oneshot;
struct Temp(PathBuf);
impl Drop for Temp {
	fn drop(&mut self) {
		std::fs::remove_dir_all(&self.0).unwrap();
	}
}
struct Bytes {
	description: FileDescription,
	bytes: Vec<u8>,
}
impl Source for Bytes {
	fn description(&self) -> &FileDescription {
		&self.description
	}
	async fn read(&self, offset: u64, length: usize) -> Result<crate::archive::Chunk, rooms_runtime::Error> {
		Ok(self.bytes[offset as usize..offset as usize + length].to_vec().into())
	}
}
fn record(id: &str, description: &FileDescription) -> Record {
	Record::new(
		Coordinates {
			source: "source".into(),
			generation: "generation".into(),
			id: id.into(),
		},
		"directory".into(),
		Body::Line {
			conversation_kind: ConversationKind::Room,
			conversation: "garden".into(),
			from: "alice".into(),
			text: "file".into(),
			mine: false,
			at: 1,
			order: 1,
			state: LineState::Present,
			previews: Default::default(),
			attachments: vec![
				Attachment::new(
					description.name().into(),
					description.mime().into(),
					description.size() as u64,
					0,
					0,
					None,
				)
				.unwrap(),
			],
		},
	)
	.unwrap()
}
fn record_message(owner: &SessionArchive, id: u64, source: File<HostPlatform>) -> Recording {
	owner
		.record_message(
			&"source".into(),
			&rooms_application::archive::recording::Message {
				keep: true,
				generation: Some(&"generation".into()),
				kind: ConversationKind::Room,
				directory: &"directory".into(),
				conversation: &"garden".into(),
				nick: "bob",
				from: "alice",
				text: "file",
				previews: &Default::default(),
				system: false,
				line: rooms_application::room::message::LineId::new(id),
				change: rooms_application::room::message::ChangeKind::Said,
				at: 1,
			},
			vec![source],
		)
		.unwrap()
		.unwrap()
}
#[tokio::test]
async fn session_archive_files_follow_their_keeper_across_selection() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(20), scenario())
				.await
				.expect("session archive file deadline");
		})
		.await;
}
async fn scenario() {
	let temp = Temp(std::env::temp_dir().join(format!("rooms-session-archive-files-{}", std::process::id())));
	std::fs::create_dir(&temp.0).unwrap();
	let peer_path = temp.0.join("peer");
	let description = FileDescription::new("file".into(), "text/plain".into(), 40_000, 0, 0).unwrap();
	let bytes: Vec<_> = (0..40_000).map(|n| (n % 251) as u8).collect();
	let mut seed = FileArchive::open(&peer_path, Options::default()).await.unwrap();
	seed.put_with_files(
		record("source", &description),
		&[Bytes {
			description: description.clone(),
			bytes: bytes.clone(),
		}],
	)
	.await
	.unwrap();
	drop(seed);
	let (stop, stopped) = oneshot::channel();
	let (ready, link) = oneshot::channel();
	let service = tokio::task::spawn_local(run(
		Config {
			state: peer_path,
			transport: Transport::Tcp {
				bind: "127.0.0.1".into(),
				port: 0,
				announce: None,
			},
		},
		async {
			let _ = stopped.await;
		},
		|link| {
			ready.send(link.to_owned()).unwrap();
		},
		Rc::new(|_| {}),
	));
	let link = link.await.unwrap();
	let runtime = Rc::new(
		Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
			.await
			.unwrap(),
	);
	let parsed = glowcap::parse_sturdyref(&link, glowcap::CaptpVersion::V1_0).unwrap();
	let session = runtime
		.connect(&parsed.locator, ConnectOptions::default())
		.await
		.unwrap();
	let reference = session.enliven(&link).await.unwrap();
	let client = Client::new(session, HostPlatform);
	let remote = Rc::new(Archive::new(client.clone(), reference));
	let source = remote.read_all(&Filter::default()).await.unwrap().remove(0);
	let blob = remote.attachment(&source.record, 0).await.unwrap();
	let source_file = || {
		File::new(
			client.clone(),
			rooms_application::room::attachment::Attachment {
				description: description.clone(),
				blob: blob.reference().clone(),
			},
		)
	};
	let (metadata, metadata_worker) =
		SessionArchive::new(rooms_platform::HostPlatform, runtime.clone(), tests::Memory::new());
	// A source read would fail: the declared file is larger than this blob.
	// Metadata-only recording must never invoke it.
	let large_source = || {
		File::new(
			client.clone(),
			rooms_application::room::attachment::Attachment {
				description: FileDescription::new(
					"large".into(),
					"text/plain".into(),
					rooms_application::files::MAX_FILE_BYTES as u64,
					0,
					0,
				)
				.unwrap(),
				blob: blob.reference().clone(),
			},
		)
	};
	let first: Vec<_> = (201..205)
		.map(|id| record_message(&metadata, id, large_source()))
		.collect();
	assert_eq!(metadata.usage().files, 0);
	assert_eq!(metadata.usage().captures, 0);
	let second = record_message(&metadata, 205, large_source());
	assert_eq!(metadata.usage().files, 0, "metadata-only work retains no source budget");
	let metadata_worker = tokio::task::spawn_local(metadata_worker.run());
	for recording in first {
		assert_eq!(
			recording.completion.wait().await.unwrap().files,
			FileRecording::MetadataOnly(MetadataReason::BackendUnsupported)
		);
	}
	assert_eq!(
		second.completion.wait().await.unwrap().files,
		FileRecording::MetadataOnly(MetadataReason::BackendUnsupported)
	);
	let records = metadata.read(Filter::default()).unwrap().wait().await.unwrap();
	assert_eq!(records.len(), 6);
	for kept in records
		.iter()
		.filter(|kept| kept.record.kind() == rooms_application::archive::Kind::Line)
	{
		let Body::Line { attachments, .. } = kept.record.body() else {
			unreachable!()
		};
		assert_eq!(attachments[0].size(), rooms_application::files::MAX_FILE_BYTES);
		assert_eq!(attachments[0].blob(), None);
	}
	let metadata_report = metadata.close().await.unwrap();
	assert_eq!(metadata_report.metadata_only_recordings, 5);
	assert_eq!(metadata_report.refused, 0);
	assert_eq!(metadata_worker.await.unwrap(), metadata_report);
	let (owner, worker) = SessionArchive::new(
		rooms_platform::HostPlatform,
		runtime.clone(),
		FileArchive::open(temp.0.join("local"), Options::default())
			.await
			.unwrap(),
	);
	let worker = tokio::task::spawn_local(worker.run());
	assert_eq!(
		record_message(&owner, 101, source_file())
			.completion
			.wait()
			.await
			.unwrap()
			.standing
			.unwrap(),
		Some(2)
	);
	let local = owner.read(Filter::default()).unwrap().wait().await.unwrap();
	assert_eq!(local.len(), 2);
	assert!(matches!(local[0].keeper, Keeper::Local(_)));
	let sources = rooms_glowcap::client::sources::Sources::new(HostPlatform);
	let forwarded_local = local[0].source(0).await.unwrap().unwrap();
	assert_eq!(forwarded_local.description(), &description);
	assert!(local[0].source(1).await.unwrap().is_none());
	let local_blob = local[0].blob(0).await.unwrap().unwrap();
	assert_eq!(local_blob.read(0, 1024).await.unwrap(), bytes[..1024]);
	let local_blob = Rc::new(local_blob);
	let mut abandoned_read = Box::pin(local_blob.read(0, 1));
	assert!(
		core::future::Future::poll(
			abandoned_read.as_mut(),
			&mut std::task::Context::from_waker(std::task::Waker::noop())
		)
		.is_pending()
	);
	let held = owner.usage();
	assert_eq!(owner.usage().requests, 1);
	assert!(
		held.bytes > core::mem::size_of::<rooms_application::archive::blobs::Reader>(),
		"queued reads retain the reader's address and scope, not just its Arc handle"
	);
	drop(abandoned_read);
	assert_eq!(
		owner.usage().bytes,
		held.bytes,
		"abandonment cannot refund queued reader storage"
	);
	reupload(&owner, &client, local_blob.clone(), description.clone(), "101", false).await;
	owner.select(Some(link.clone())).unwrap().wait().await.unwrap();
	let share = rooms_application::archive::shares::Share::new(
		"12345678-1234-4234-8234-123456789abc".into(),
		"Archive".into(),
		Filter::default(),
	)
	.unwrap();
	let shared_link = owner.issue_share(share.clone()).unwrap().wait().await.unwrap();
	owner.prepare(shared_link.clone()).unwrap().wait().await.unwrap();
	owner.select(Some(shared_link)).unwrap().wait().await.unwrap();
	assert!(
		owner.shares().unwrap().wait().await.is_err(),
		"a shared facet became its issuer"
	);
	owner.select(Some(link.clone())).unwrap().wait().await.unwrap();
	assert_eq!(owner.shares().unwrap().wait().await.unwrap()[0].share, share);
	assert!(owner.revoke_share(share.id().into()).unwrap().wait().await.unwrap());
	assert!(owner.shares().unwrap().wait().await.unwrap().is_empty());
	assert_eq!(
		record_message(&owner, 102, source_file())
			.completion
			.wait()
			.await
			.unwrap()
			.standing
			.unwrap(),
		Some(3)
	);
	let merged = owner.read(Filter::default()).unwrap().wait().await.unwrap();
	assert_eq!(merged.len(), 4);
	let copied = merged
		.iter()
		.find(|k| k.record.coordinates().id == rooms_application::text::DocumentText::from("102"))
		.unwrap();
	assert!(matches!(copied.keeper, Keeper::Peer(_)));
	remote
		.put_sources(&sources, &record("102", &description), vec![forwarded_local])
		.await
		.unwrap();
	let forwarded_peer = copied.source(0).await.unwrap().unwrap();
	let retired_local = local[0].source(0).await.unwrap().unwrap();
	let retired_peer = copied.source(0).await.unwrap().unwrap();
	let peer_blob = copied.blob(0).await.unwrap().unwrap();
	reupload(&owner, &client, local_blob.clone(), description.clone(), "102", false).await;
	owner.select(None).unwrap().wait().await.unwrap();
	assert!(owner.shares().unwrap().wait().await.is_err());
	remote
		.put_sources(&sources, &record("102", &description), vec![forwarded_peer])
		.await
		.unwrap();
	assert_eq!(peer_blob.read(32_000, 8000).await.unwrap(), bytes[32_000..]);
	assert_eq!(local_blob.read(32_000, 8000).await.unwrap(), bytes[32_000..]);
	reupload(&owner, &client, local_blob.clone(), description.clone(), "101", true).await;
	assert!(local_blob.read(0, 1).await.is_err());
	assert!(
		remote
			.put_sources(&sources, &record("erased", &description), vec![retired_local])
			.await
			.is_err()
	);
	assert_eq!(peer_blob.read(0, 1024).await.unwrap(), bytes[..1024]);
	let report = owner.close().await.unwrap();
	assert_eq!(report.cleanup_failures, 0);
	assert_eq!(report.lost_replies, 1);
	assert!(peer_blob.read(0, 1).await.is_err());
	assert!(
		remote
			.put_sources(&sources, &record("retired", &description), vec![retired_peer])
			.await
			.is_err()
	);
	assert!(sources.take_failure().is_none());
	drop(sources);
	assert_eq!(worker.await.unwrap(), report);
	// Closing this archive owner revoked its views without closing the same
	// transport retained by the source client, even while those views survive.
	assert!(client.session().is_open());
	assert_eq!(remote.read_all(&Filter::default()).await.unwrap().len(), 3);
	assert_eq!(blob.read(0, 1024).await.unwrap(), bytes[..1024]);
	// A put whose source has not answered holds only its own record. The
	// revocation, the narrow, and the byte read queued behind it are all
	// answered while its bytes are still outstanding, in the order they came.
	let pending_source = Rc::new(std::cell::RefCell::new(None));
	let pending_reply = pending_source.clone();
	let source_started = Rc::new(tokio::sync::Notify::new());
	let started = source_started.clone();
	let source_host = client.session().host();
	let delayed = client
		.session()
		.spawn_owned(move |_, _| {
			*pending_reply.borrow_mut() = Some(source_host.defer_turn().map_err(|e| e.to_string())?);
			started.notify_one();
			Ok(glowcap::Argument::Void)
		})
		.unwrap();
	let one_byte = FileDescription::new("one".into(), "text/plain".into(), 1, 0, 0).unwrap();
	let uploading = remote.clone();
	let upload = tokio::task::spawn_local(async move {
		uploading
			.put_files(
				&record("delayed-copy", &one_byte),
				&[rooms_application::room::attachment::Attachment {
					description: one_byte,
					blob: delayed,
				}],
			)
			.await
	});
	source_started.notified().await;
	let revoking = remote.clone();
	let revoke = tokio::task::spawn_local(async move { revoking.revoke_share("unknown").await });
	tokio::task::yield_now().await;
	drop(
		remote
			.narrow(&Filter::default(), rooms_application::archive::Access::Read)
			.await
			.unwrap(),
	);
	assert_eq!(
		blob.read(0, 1).await.unwrap(),
		bytes[..1],
		"a byte read was held behind an unfinished put"
	);
	assert!(
		!revoke.await.unwrap().unwrap(),
		"a revocation was held behind an unfinished put"
	);
	pending_source
		.borrow_mut()
		.take()
		.unwrap()
		.fulfill(&glowcap::Argument::Bytes(vec![9]))
		.unwrap();
	upload.await.unwrap().unwrap();
	assert_eq!(blob.read(0, 1).await.unwrap(), bytes[..1]);
	let (interrupted, task) = SessionArchive::new(
		rooms_platform::HostPlatform,
		runtime.clone(),
		FileArchive::open(temp.0.join("interrupted"), Options::default())
			.await
			.unwrap(),
	);
	let task = tokio::task::spawn_local(task.run());
	interrupted.select(Some(link.clone())).unwrap().wait().await.unwrap();
	let held = interrupted.read(Filter::default()).unwrap().wait().await.unwrap();
	task.abort();
	assert!(task.await.unwrap_err().is_cancelled());
	assert!(
		interrupted.close().await.is_err(),
		"interrupted execution claimed a clean barrier"
	);
	assert!(held[0].blob(0).await.is_err());
	assert!(client.session().is_open());
	drop(held);
	capture_tests::run(runtime.clone(), &client, &link, &temp.0).await;
	drop(local_blob);
	drop(peer_blob);
	drop(local);
	drop(merged);
	drop(blob);
	drop(remote);
	client.session().close(PendingWork::Cancel).await.unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
	stop.send(()).unwrap();
	service.await.unwrap().unwrap();
}

async fn reupload(
	owner: &SessionArchive,
	client: &Client<HostPlatform>,
	blob: Rc<ArchivedBlob>,
	description: FileDescription,
	id: &str,
	fence: bool,
) {
	let tasks = Rc::new(std::cell::RefCell::new(Vec::new()));
	let workers = tasks.clone();
	let started = Rc::new(tokio::sync::Notify::new());
	let arrived = started.clone();
	let gate = Rc::new(tokio::sync::Notify::new());
	let released = gate.clone();
	let proxy = client
		.session()
		.spawn_owned(move |verb, args| {
			let [glowcap::Argument::Integer(offset), glowcap::Argument::Integer(length)] = args else {
				return Err("read arguments".into());
			};
			if verb != "read" || *offset < 0 || *length < 1 {
				return Err("read range".into());
			}
			let (offset, length) = (*offset as u64, *length as usize);
			let mut answer = glowcap::current_session()
				.map_err(|e| e.to_string())?
				.ok_or("caller")?
				.host()
				.defer_turn()
				.map_err(|e| e.to_string())?;
			let blob = blob.clone();
			let gate = released.clone();
			arrived.notify_one();
			workers.borrow_mut().push(tokio::task::spawn_local(async move {
				if fence {
					gate.notified().await;
				}
				// The deadline also unwinds a broken serial implementation, so the
				// regression reports its cause without leaving a disk job waiting.
				match tokio::time::timeout(Duration::from_secs(5), blob.read(offset, length)).await {
					Ok(Ok(bytes)) => answer.fulfill(&glowcap::Argument::Bytes(bytes)).unwrap(),
					Ok(Err(error)) => answer.break_with(&error.into_refusal()).unwrap(),
					Err(_) => answer.break_with("local archive source callback deadlocked").unwrap(),
				}
			}));
			Ok(glowcap::Argument::Void)
		})
		.unwrap();
	let source = File::new(
		client.clone(),
		rooms_application::room::attachment::Attachment {
			description: description.clone(),
			blob: proxy.clone(),
		},
	);
	let recording = owner.put(record(id, &description), vec![source]).unwrap();
	let (result, ()) = tokio::join!(recording.wait(), async {
		if fence {
			started.notified().await;
			let erase = owner.clear_local().unwrap();
			gate.notify_one();
			erase.wait().await.unwrap();
		}
	});
	let tasks = core::mem::take(&mut *tasks.borrow_mut());
	for task in tasks {
		task.await.unwrap();
	}
	client.session().release(proxy).unwrap();
	if fence {
		assert!(
			result.unwrap_err().to_string().contains("fenced"),
			"erasure must refuse callbacks after its admission"
		);
	} else {
		result.expect("a local source must serve committed blob callbacks during ingestion");
	}
}
