use super::*;
use crate::archive::BlobAccess;
use glowcap::{Argument, Ref, Resolver};
use rooms_application::{
	archive::{index::Page, recording::Message},
	files::CHUNK_BYTES,
	room::message::{ChangeKind, LineId},
};
use std::{cell::RefCell, path::Path};
use tokio::sync::Notify;

struct Delayed {
	inner: FileArchive,
	started: Rc<Notify>,
	release: Rc<Notify>,
	first: bool,
}
impl Backend for Delayed {
	fn retains_blobs(&self) -> bool {
		true
	}
	fn blob_access(&self) -> impl BlobAccess + use<> {
		self.inner.blob_access()
	}
	async fn put(&mut self, record: Record) -> Result<u64, String> {
		if self.first {
			self.first = false;
			self.started.notify_one();
			self.release.notified().await;
		}
		self.inner.put(record).await
	}
	async fn put_files<S: Source>(&mut self, record: Record, files: &[S]) -> Result<u64, String> {
		let one = files[0].read(0, 1).await?;
		let again = files[0].read(0, 1).await?;
		assert_eq!(
			one.as_ref().as_ptr(),
			again.as_ref().as_ptr(),
			"local capture reads must share the retained allocation"
		);
		self.inner.put_with_files(record, files).await
	}
	async fn read(&mut self, filter: &Filter, after: u64, limit: usize) -> Result<Page, String> {
		self.inner.read(filter, after, limit).await
	}
	async fn blob_reader(
		&mut self,
		facet: rooms_application::archive::Facet,
		digest: String,
	) -> Result<rooms_application::archive::blobs::Reader, String> {
		self.inner.blob_reader(facet, digest).await
	}
	async fn read_blob(
		&mut self,
		reader: rooms_application::archive::blobs::Reader,
		offset: u64,
		maximum: usize,
	) -> Result<Vec<u8>, String> {
		self.inner.read_blob(reader, offset, maximum).await
	}
}
fn admit(owner: &SessionArchive, id: u64, files: Vec<File<Deadline>>) -> Recording {
	owner
		.record_message(
			&"capture-source".into(),
			&Message {
				keep: true,
				generation: Some(&"capture-generation".into()),
				kind: ConversationKind::Room,
				directory: &"capture-directory".into(),
				conversation: &"capture".into(),
				nick: "alice",
				from: "bob",
				text: "captured",
				system: false,
				line: LineId::new(id),
				change: ChangeKind::Said,
				at: 123,
			},
			files,
		)
		.unwrap()
		.unwrap()
}
fn file(client: &Client<Deadline>, root: &Ref, size: usize) -> File<Deadline> {
	File::new(
		client.clone(),
		rooms_application::room::attachment::Attachment {
			description: FileDescription::new(
				format!("file-{size}"),
				"application/octet-stream".into(),
				size as u64,
				0,
				0,
			)
			.unwrap(),
			blob: root.clone(),
		},
	)
}
pub(super) async fn run(runtime: Rc<Runtime>, client: &Client<Deadline>, link: &str, path: &Path) {
	for remote in [false, true] {
		survives(runtime.clone(), client, remote.then_some(link), path).await;
	}
	pressure(runtime.clone(), client, path, false).await;
	pressure(runtime.clone(), client, path, true).await;
	stalled_source_leaves_reads_flowing(runtime.clone(), client, path).await;
	aborted(runtime, client, path).await;
	scoped_sources(client).await;
}

/// A source that never answers holds only its own line. Reads, and lines
/// admitted after it, are served while its bytes are outstanding; when the
/// source finally fails, its line lands without bytes rather than never.
///
/// Validated against the defect it guards: with the capture awaited on the
/// worker's own spine, the read below times out.
async fn stalled_source_leaves_reads_flowing(runtime: Rc<Runtime>, client: &Client<Deadline>, path: &Path) {
	let answer = Rc::new(RefCell::new(None::<Resolver>));
	let pending = answer.clone();
	let root = client
		.session()
		.spawn_owned(move |_, _| {
			*pending.borrow_mut() = Some(
				glowcap::current_session()
					.map_err(|e| e.to_string())?
					.ok_or("caller")?
					.host()
					.defer_turn()
					.map_err(|e| e.to_string())?,
			);
			Ok(Argument::Void)
		})
		.unwrap();
	let (owner, worker) = SessionArchive::new(
		crate::client::Deadline,
		runtime,
		FileArchive::open(path.join("capture-stall"), Options::default())
			.await
			.unwrap(),
	);
	let mut changes = owner.changes();
	let worker = tokio::task::spawn_local(worker.run());
	let stalled = admit(&owner, 801, vec![file(client, &root, CHUNK_BYTES)]);
	while answer.borrow().is_none() {
		tokio::task::yield_now().await;
	}
	let read = tokio::time::timeout(
		core::time::Duration::from_secs(2),
		owner.read(Filter::default()).unwrap().wait(),
	)
	.await
	.expect("a read is answered while a capture waits on its source")
	.unwrap();
	assert!(read.is_empty(), "the stalled line is not yet archived");
	assert!(
		matches!(
			changes.try_recv(),
			Err(tokio::sync::broadcast::error::TryRecvError::Empty)
		),
		"admission is not a history commitment"
	);
	let later = admit(&owner, 802, Vec::new()).completion.wait().await.unwrap();
	assert_eq!(later.revision, 1, "a later line lands ahead of the stalled one");
	let scope = rooms_application::archive::change::Change::Conversation {
		kind: rooms_application::archive::ConversationKind::Room,
		directory: "capture-directory".into(),
		conversation: "capture".into(),
	};
	assert_eq!(changes.try_recv().unwrap(), scope);
	assert!(
		changes.try_recv().is_err(),
		"standing writes do not invalidate conversation history"
	);
	answer
		.borrow_mut()
		.take()
		.unwrap()
		.break_with("the view holding this file is gone")
		.unwrap();
	let landed = stalled.completion.wait().await.unwrap();
	assert_eq!(
		landed.revision, 3,
		"the stalled line lands after its standing-free sibling"
	);
	let FileRecording::MetadataOnly(MetadataReason::SourceFailed(reason)) = landed.files else {
		panic!("a source that failed leaves its line archived without bytes");
	};
	assert!(reason.contains("the view holding this file is gone"), "{reason}");
	assert_eq!(
		changes.try_recv().unwrap(),
		scope,
		"late metadata commitment invalidates the earlier read"
	);
	let kept = owner.read(Filter::default()).unwrap().wait().await.unwrap();
	let lines = kept
		.iter()
		.filter(|kept| matches!(kept.record.body(), rooms_application::archive::Body::Line { .. }))
		.count();
	assert_eq!(lines, 2, "both lines are archived, in the order their bytes landed");
	let report = owner.close().await.unwrap();
	assert_eq!(report.refused, 0);
	assert_eq!(report.metadata_only_recordings, 1);
	assert_eq!(worker.await.unwrap(), report);
	client.session().release(root).unwrap();
}

async fn aborted(runtime: Rc<Runtime>, client: &Client<Deadline>, path: &Path) {
	let answer = Rc::new(RefCell::new(None::<Resolver>));
	let pending = answer.clone();
	let root = client
		.session()
		.spawn_owned(move |_, _| {
			*pending.borrow_mut() = Some(
				glowcap::current_session()
					.map_err(|e| e.to_string())?
					.ok_or("caller")?
					.host()
					.defer_turn()
					.map_err(|e| e.to_string())?,
			);
			Ok(Argument::Void)
		})
		.unwrap();
	let (owner, worker) = SessionArchive::new(
		crate::client::Deadline,
		runtime,
		FileArchive::open(path.join("capture-aborted"), Options::default())
			.await
			.unwrap(),
	);
	let worker = tokio::task::spawn_local(worker.run());
	let recording = admit(&owner, 800, vec![file(client, &root, 1)]);
	while answer.borrow().is_none() {
		tokio::task::yield_now().await;
	}
	assert_eq!(owner.usage().captures, 1);
	worker.abort();
	assert!(worker.await.unwrap_err().is_cancelled());
	assert!(owner.close().await.is_err());
	assert!(recording.completion.wait().await.is_err());
	while owner.usage().captures != 0 {
		tokio::task::yield_now().await;
	}
	assert_eq!(owner.usage().requests, 0);
	assert_eq!(owner.usage().files, 0);
	answer
		.borrow_mut()
		.take()
		.unwrap()
		.break_with("capture owner retired")
		.unwrap();
	assert!(client.session().is_open());
	client.session().release(root).unwrap();
}

async fn scoped_sources(client: &Client<Deadline>) {
	use rooms_glowcap::client::sources::{Source as Backing, Sources};
	let held = Rc::new(RefCell::new(Vec::<Ref>::new()));
	let received = held.clone();
	let receiver = client
		.session()
		.spawn_owned(move |verb, args| {
			if verb != "putFiles" {
				return Err("fixture method".into());
			}
			let Some(Argument::Reference(blob)) = args.get(5) else {
				return Err("fixture source".into());
			};
			received.borrow_mut().push(blob.clone());
			Ok(Argument::Integer(1))
		})
		.unwrap();
	let archive = Archive::new(client.clone(), receiver.clone());
	let pool = Sources::new(Deadline);
	let description = FileDescription::new("file".into(), "text/plain".into(), 2, 0, 0).unwrap();
	let row = record("scoped", &description);
	archive
		.put_sources(
			&pool,
			&row,
			vec![Backing::bytes(description.clone(), vec![7, 8]).unwrap()],
		)
		.await
		.unwrap();
	let scoped = held.borrow()[0].clone();
	assert!(
		client
			.session()
			.send(&scoped, "read", &[0.into(), 1.into()])
			.await
			.is_err(),
		"archive acknowledgement ends temporary source authority"
	);
	assert_eq!(pool.usage().bytes, 0);
	pool.send(
		client,
		&receiver,
		"putFiles",
		vec![rooms_glowcap::archive::record_row(&row)],
		vec![Backing::bytes(description, vec![7, 8]).unwrap()],
	)
	.await
	.unwrap();
	let delivered = held.borrow()[1].clone();
	assert_eq!(
		client
			.session()
			.send(&delivered, "read", &[0.into(), 1.into()])
			.await
			.unwrap()
			.as_bytes(),
		Some([7].as_slice())
	);
	drop(pool);
	assert!(client
		.session()
		.send(&delivered, "read", &[0.into(), 1.into()])
		.await
		.is_err());
	drop((archive, held, scoped, delivered));
	client.session().release(receiver).unwrap();
}
async fn survives(runtime: Rc<Runtime>, client: &Client<Deadline>, target: Option<&str>, path: &Path) {
	let live = Rc::new(Cell::new(true));
	let active = live.clone();
	let reads = Rc::new(Cell::new(0));
	let count = reads.clone();
	let bytes: Rc<Vec<u8>> = Rc::new((0..CHUNK_BYTES + 3).map(|n| (n % 251) as u8).collect());
	let content = bytes.clone();
	let root = client
		.session()
		.spawn_owned(move |verb, args| {
			let [Argument::Integer(offset), Argument::Integer(length)] = args else {
				return Err("source arguments".into());
			};
			if verb != "read" || !active.get() {
				return Err("source retired".into());
			}
			count.set(count.get() + 1);
			let span = content
				.get(*offset as usize..(*offset + *length) as usize)
				.ok_or("source range")?;
			Ok(Argument::Bytes(span.to_vec()))
		})
		.unwrap();
	let started = Rc::new(Notify::new());
	let release = Rc::new(Notify::new());
	let (owner, worker) = SessionArchive::new(
		crate::client::Deadline,
		runtime,
		Delayed {
			inner: FileArchive::open(
				path.join(if target.is_some() {
					"capture-peer"
				} else {
					"capture-local"
				}),
				Options::default(),
			)
			.await
			.unwrap(),
			started: started.clone(),
			release: release.clone(),
			first: true,
		},
	);
	let mut changes = owner.changes();
	let worker = tokio::task::spawn_local(worker.run());
	let blocked = owner
		.put(
			record("block", &file(client, &root, 1).attachment().description),
			vec![],
		)
		.unwrap();
	started.notified().await;
	let selection = target.map(|link| owner.select(Some(link.into())).unwrap());
	let id = if target.is_some() { 502 } else { 501 };
	let recording = admit(
		&owner,
		id,
		vec![file(client, &root, bytes.len()), file(client, &root, 1)],
	);
	while owner.usage().captures != 0 {
		tokio::task::yield_now().await;
	}
	assert_eq!(
		reads.get(),
		3,
		"all files must capture while the prior write is blocked"
	);
	assert_eq!(
		owner.usage().files,
		bytes.len() + 1,
		"completed capture stays charged until persistence"
	);
	live.set(false);
	drop(recording);
	release.notify_one();
	blocked.wait().await.unwrap();
	if let Some(selection) = selection {
		selection.wait().await.unwrap();
	}
	let rows = owner
		.read(Filter {
			directory: Some("capture-directory".into()),
			..Default::default()
		})
		.unwrap()
		.wait()
		.await
		.unwrap();
	let mut notified = false;
	while let Ok(change) = changes.try_recv() {
		notified |= matches!(change, rooms_application::archive::change::Change::Conversation { directory, conversation, .. }
			if directory.as_str() == Some("capture-directory") && conversation.as_str() == Some("capture"));
	}
	assert!(notified, "abandoning a receipt does not abandon history invalidation");
	let kept = rows
		.iter()
		.find(|row| row.record.coordinates().id.as_str() == Some(id.to_string().as_str()))
		.unwrap();
	assert_eq!(
		kept.blob(0)
			.await
			.unwrap()
			.unwrap()
			.read((CHUNK_BYTES - 2) as u64, 5)
			.await
			.unwrap(),
		bytes[CHUNK_BYTES - 2..]
	);
	assert_eq!(
		kept.blob(1).await.unwrap().unwrap().read(0, 1).await.unwrap(),
		bytes[..1]
	);
	assert_eq!(reads.get(), 3, "storage must not return to retired sources");
	let report = owner.close().await.unwrap();
	assert_eq!(report.refused, 0);
	assert_eq!(report.lost_replies, 1);
	assert_eq!(worker.await.unwrap(), report);
	assert_eq!(owner.usage().files, 0);
	client.session().release(root).unwrap();
}

async fn pressure(runtime: Rc<Runtime>, client: &Client<Deadline>, path: &Path, streams: bool) {
	let answers = Rc::new(RefCell::new(Vec::<Resolver>::new()));
	let pending = answers.clone();
	let root = client
		.session()
		.spawn_owned(move |_, _| {
			let reply = glowcap::current_session()
				.map_err(|e| e.to_string())?
				.ok_or("caller")?
				.host()
				.defer_turn()
				.map_err(|e| e.to_string())?;
			pending.borrow_mut().push(reply);
			Ok(Argument::Void)
		})
		.unwrap();
	let (owner, worker) = SessionArchive::new(
		crate::client::Deadline,
		runtime,
		FileArchive::open(
			path.join(if streams {
				"capture-stream-pressure"
			} else {
				"capture-byte-pressure"
			}),
			Options::default(),
		)
		.await
		.unwrap(),
	);
	let (count, size, reason) = if streams {
		(MAX_STREAMS, 1, MetadataReason::PendingCaptures)
	} else {
		(
			4,
			rooms_application::files::MAX_FILE_BYTES,
			MetadataReason::PendingBytes,
		)
	};
	let mut recordings = Vec::new();
	for id in 0..count {
		recordings.push(admit(&owner, 601 + id as u64, vec![file(client, &root, size)]));
	}
	let metadata = admit(&owner, 700, vec![file(client, &root, size)]);
	assert_eq!(owner.usage().captures, count);
	assert_eq!(owner.usage().files, count * size);
	while answers.borrow().len() != count {
		tokio::task::yield_now().await;
	}
	let replies = core::mem::take(&mut *answers.borrow_mut());
	for mut reply in replies {
		reply.break_with("source capture refused").unwrap();
	}
	let worker = tokio::task::spawn_local(worker.run());
	// A source that refuses its bytes does not cost the line: it is kept the
	// way its room keeps it, with the file named and the refusal recorded.
	for recording in recordings {
		let FileRecording::MetadataOnly(MetadataReason::SourceFailed(refusal)) =
			recording.completion.wait().await.unwrap().files
		else {
			panic!("a refused source leaves a metadata-only line");
		};
		assert!(refusal.contains("source capture refused"), "{refusal}");
	}
	assert_eq!(
		metadata.completion.wait().await.unwrap().files,
		FileRecording::MetadataOnly(reason)
	);
	let report = owner.close().await.unwrap();
	assert_eq!(report.refused, 0);
	assert_eq!(report.metadata_only_recordings, count as u64 + 1);
	assert_eq!(worker.await.unwrap(), report);
	assert_eq!(owner.usage().captures, 0);
	assert_eq!(owner.usage().files, 0);
	client.session().release(root).unwrap();
}
