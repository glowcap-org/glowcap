use super::{tests::Temp, *};
use rooms_application::{
	archive::{
		blobs::{self as policy, Reader},
		Access, Attachment, Body, ConversationKind, Coordinates, Facet, LineState,
	},
	files::{FileDescription, CHUNK_BYTES},
};
use std::{cell::RefCell, fs, time::Duration};
pub(super) struct Bytes {
	description: FileDescription,
	bytes: Vec<u8>,
	reads: RefCell<Vec<(u64, usize)>>,
	stall: bool,
}
impl Bytes {
	pub(super) fn new(bytes: Vec<u8>) -> Self {
		Self {
			description: FileDescription::new("file".into(), "text/plain".into(), bytes.len() as u64, 0, 0).unwrap(),
			bytes,
			reads: RefCell::new(Vec::new()),
			stall: false,
		}
	}
}
impl Source for Bytes {
	fn description(&self) -> &FileDescription {
		&self.description
	}
	async fn read(&self, offset: u64, length: usize) -> Result<crate::archive::file::Chunk, String> {
		self.reads.borrow_mut().push((offset, length));
		if self.stall && offset > 0 {
			std::future::pending::<()>().await;
		}
		Ok(self.bytes[offset as usize..offset as usize + length].to_vec().into())
	}
}
pub(super) fn line(id: &str, sources: &[Bytes]) -> Record {
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
			text: "hello".into(),
			mine: false,
			at: 1,
			order: 1,
			state: LineState::Present,
			attachments: sources
				.iter()
				.map(|s| {
					let d = s.description();
					Attachment::new(d.name().into(), d.mime().into(), d.size() as u64, 0, 0, None).unwrap()
				})
				.collect(),
		},
	)
	.unwrap()
}
fn facet() -> Facet {
	Facet::new(Filter::default(), Access::Read).unwrap()
}
async fn latest(archive: &mut FileArchive) -> Arc<Record> {
	archive
		.read(&Filter::default(), 0, 128)
		.await
		.unwrap()
		.records
		.last()
		.unwrap()
		.record
		.clone()
}
#[tokio::test]
async fn blobs_stream_restart_and_check_content_without_materializing_files() {
	let temp = Temp::new();
	let mut archive = FileArchive::open(&temp.0, Options::default()).await.unwrap();
	let sources = [
		Bytes::new((0..CHUNK_BYTES + 7).map(|n| (n % 251) as u8).collect()),
		Bytes::new(vec![]),
	];
	assert_eq!(
		archive.put_with_files(line("one", &sources), &sources).await.unwrap(),
		1
	);
	assert_eq!(*sources[0].reads.borrow(), [(0, CHUNK_BYTES), (CHUNK_BYTES as u64, 7)]);
	assert!(sources[1].reads.borrow().is_empty());
	let record = latest(&mut archive).await;
	let reader = Reader::attachment(&facet(), &record, 0).unwrap();
	let empty = Reader::attachment(&facet(), &record, 1).unwrap();
	assert_eq!(
		archive.read_blob(reader.clone(), 0, CHUNK_BYTES).await.unwrap(),
		sources[0].bytes[..CHUNK_BYTES]
	);
	assert_eq!(
		archive
			.read_blob(reader.clone(), CHUNK_BYTES as u64, CHUNK_BYTES)
			.await
			.unwrap(),
		sources[0].bytes[CHUNK_BYTES..]
	);
	assert!(archive.read_blob(empty, 0, 1).await.unwrap().is_empty());
	assert_eq!(archive.blob_usage().await.unwrap().retained_bytes, CHUNK_BYTES + 7);
	let digest = policy::files(&record).unwrap()[0].blob().unwrap().to_string();
	drop(archive);
	let mut archive = FileArchive::open(&temp.0, Options::default()).await.unwrap();
	let found = archive.reader_for_digest(facet(), digest.clone()).await.unwrap();
	assert_eq!(
		archive.read_blob(found, CHUNK_BYTES as u64, 7).await.unwrap(),
		sources[0].bytes[CHUNK_BYTES..]
	);
	drop(archive);
	fs::write(temp.0.join("blobs").join(&digest), vec![0; CHUNK_BYTES + 7]).unwrap();
	let mut archive = FileArchive::open(&temp.0, Options::default()).await.unwrap();
	assert!(archive.read_blob(reader, 0, 1).await.unwrap_err().contains("digest"));
	// Re-uploading the exact content repairs a corrupted referenced blob.
	archive.put_with_files(line("one", &sources), &sources).await.unwrap();
	assert_eq!(archive.blob_usage().await.unwrap().retained_bytes, CHUNK_BYTES + 7);
}
#[tokio::test]
async fn reference_accounting_deduplicates_and_reclaims_only_after_commit() {
	let temp = Temp::new();
	let options = Options {
		max_blob_bytes: 7,
		..Default::default()
	};
	let mut archive = FileArchive::open(&temp.0, options).await.unwrap();
	let sources = [Bytes::new(b"content".to_vec()), Bytes::new(b"content".to_vec())];
	archive.put_with_files(line("one", &sources), &sources).await.unwrap();
	let old = latest(&mut archive).await;
	let reader = Reader::attachment(&facet(), &old, 0).unwrap();
	assert_eq!(archive.blob_usage().await.unwrap().retained_bytes, 7);
	let other = [Bytes::new(b"changed".to_vec())];
	assert!(archive.put_with_files(line("two", &other), &other).await.is_err());
	assert_eq!(archive.read_blob(reader.clone(), 0, 7).await.unwrap(), b"content");
	assert_eq!(archive.blob_usage().await.unwrap().orphan_bytes, 0);
	// Retirement frees the prior digest's charge in the proposed committed state.
	archive.put_with_files(line("one", &other), &other).await.unwrap();
	assert!(archive.read_blob(reader, 0, 7).await.is_err());
	let now = latest(&mut archive).await;
	let reader = Reader::attachment(&facet(), &now, 0).unwrap();
	assert_eq!(archive.read_blob(reader, 0, 7).await.unwrap(), b"changed");
	assert_eq!(fs::read_dir(temp.0.join("blobs")).unwrap().count(), 1);
	let empty: [Bytes; 0] = [];
	archive.put(line("one", &empty)).await.unwrap();
	assert_eq!(archive.blob_usage().await.unwrap(), BlobUsage::default());
	drop(archive);
	fs::write(temp.0.join("blobs").join("orphan"), b"lost").unwrap();
	let mut archive = FileArchive::open(&temp.0, options).await.unwrap();
	assert_eq!(archive.blob_usage().await.unwrap(), BlobUsage::default());
	assert_eq!(fs::read_dir(temp.0.join("blobs")).unwrap().count(), 0);
}
#[tokio::test]
async fn cancelled_source_and_unchanged_journal_failure_cleanup_staging() {
	let temp = Temp::new();
	let mut archive = FileArchive::open(&temp.0, Options::default()).await.unwrap();
	let mut source = Bytes::new(vec![1; CHUNK_BYTES + 1]);
	source.stall = true;
	let sources = [source];
	assert!(tokio::time::timeout(
		Duration::from_millis(30),
		archive.put_with_files(line("one", &sources), &sources)
	)
	.await
	.is_err());
	assert!(archive.finish_pending().await.is_err());
	assert_eq!(archive.read(&Filter::default(), 0, 128).await.unwrap().next, 0);
	assert_eq!(archive.blob_usage().await.unwrap(), BlobUsage::default());
	let backup = temp.0.join("journal-backup");
	fs::rename(temp.file(), &backup).unwrap();
	fs::create_dir(temp.file()).unwrap();
	let sources = [Bytes::new(b"content".to_vec())];
	assert!(archive.put_with_files(line("one", &sources), &sources).await.is_err());
	assert_eq!(archive.blob_usage().await.unwrap(), BlobUsage::default());
	fs::remove_dir(temp.file()).unwrap();
	fs::rename(backup, temp.file()).unwrap();
	assert_eq!(
		archive.put_with_files(line("one", &sources), &sources).await.unwrap(),
		1
	);
}

#[tokio::test]
async fn uncertain_journal_keeps_staged_bytes_for_recovery() {
	let temp = Temp::new();
	let path = temp.0.clone();
	tokio::task::spawn_blocking(move || {
		let mut store = Store::open(path, Options::default()).unwrap();
		let sources = [Bytes::new(b"content".to_vec())];
		let (send, mut chunks) = tokio::sync::mpsc::channel(1);
		assert!(send.blocking_send(Ok(b"content".to_vec().into())).is_ok());
		drop(send);
		let blobs = store.blobs.as_mut().unwrap();
		let staged = blobs.begin(7).unwrap().write(&mut chunks).unwrap();
		let digest = blobs.finish(staged).unwrap();
		let record = line("one", &sources).with_blob_digests(vec![digest]).unwrap();
		let digest = policy::files(&record).unwrap()[0].blob().unwrap().to_string();
		let mut proposed = Index::new(5000).unwrap();
		proposed.apply(1, record).unwrap();
		let snapshot = disk::snapshot(&proposed, disk::MAX_FILE_BYTES).unwrap();
		let outcome = storage::atomic::replace_with_sync(&store.directory, disk::FILE, snapshot.chunks(), || {
			Err(std::io::Error::other("injected directory sync failure"))
		});
		let error = store.written(outcome).unwrap_err();
		assert!(store.finish_file_put(Err(error)).is_err());
		assert!(!store.ready);
		assert_eq!(
			fs::read(store.directory.path.join("blobs").join(digest)).unwrap(),
			b"content"
		);
	})
	.await
	.unwrap();
	let mut restored = FileArchive::open(&temp.0, Options::default()).await.unwrap();
	let record = latest(&mut restored).await;
	let reader = Reader::attachment(&facet(), &record, 0).unwrap();
	assert_eq!(restored.read_blob(reader, 0, 7).await.unwrap(), b"content");
}

#[tokio::test]
async fn disk_refusal_ends_a_source_that_never_answers() {
	struct Stalled(FileDescription);
	impl Source for Stalled {
		fn description(&self) -> &FileDescription {
			&self.0
		}
		async fn read(&self, _: u64, _: usize) -> Result<crate::archive::file::Chunk, String> {
			std::future::pending().await
		}
	}
	let temp = Temp::new();
	let mut archive = FileArchive::open(&temp.0, Options::default()).await.unwrap();
	archive.store.lock().unwrap().ready = false;
	let bytes = [Bytes::new(vec![1])];
	let sources = [Stalled(bytes[0].description.clone())];
	let result = tokio::time::timeout(
		Duration::from_secs(1),
		archive.put_with_files(line("one", &bytes), &sources),
	)
	.await
	.unwrap();
	assert!(result.unwrap_err().contains("reload"));
	assert!(archive.pending.is_none());
}

#[tokio::test]
async fn metadata_never_invents_bytes_and_record_eviction_reclaims_attachments() {
	let temp = Temp::new();
	let options = Options {
		capacity: 1,
		..Default::default()
	};
	let mut archive = FileArchive::open(&temp.0, options).await.unwrap();
	let sources = [Bytes::new(b"content".to_vec())];
	archive.put(line("metadata", &sources)).await.unwrap();
	let record = latest(&mut archive).await;
	assert_eq!(policy::files(&record).unwrap().len(), 1);
	assert!(Reader::attachment(&facet(), &record, 0).is_err());
	assert_eq!(archive.blob_usage().await.unwrap(), BlobUsage::default());
	drop(archive);
	let mut archive = FileArchive::open(&temp.0, options).await.unwrap();
	assert!(Reader::attachment(&facet(), latest(&mut archive).await.as_ref(), 0).is_err());
	archive.put_with_files(line("first", &sources), &sources).await.unwrap();
	let old = Reader::attachment(&facet(), latest(&mut archive).await.as_ref(), 0).unwrap();
	let replacement = [Bytes::new(b"next".to_vec())];
	archive
		.put_with_files(line("second", &replacement), &replacement)
		.await
		.unwrap();
	assert!(archive.read_blob(old, 0, 7).await.is_err());
	assert_eq!(archive.blob_usage().await.unwrap().retained_bytes, 4);
	assert_eq!(fs::read_dir(temp.0.join("blobs")).unwrap().count(), 1);
	drop(archive);
	let mut archive = FileArchive::open(&temp.0, options).await.unwrap();
	let current = Reader::attachment(&facet(), latest(&mut archive).await.as_ref(), 0).unwrap();
	assert_eq!(archive.read_blob(current, 0, 4).await.unwrap(), b"next");
	assert_eq!(archive.read(&Filter::default(), 0, 128).await.unwrap().next, 3);
}
