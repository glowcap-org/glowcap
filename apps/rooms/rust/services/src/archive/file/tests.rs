use super::*;
use rooms_application::{
	archive::{Body, ConversationKind, Coordinates, LineState},
	text::DocumentText,
};
use std::{
	fs, io,
	sync::atomic::{AtomicU64, Ordering},
	time::Duration,
};
static NEXT: AtomicU64 = AtomicU64::new(0);
pub(super) struct Temp(pub(super) PathBuf);
impl Temp {
	pub(super) fn new() -> Self {
		let path = std::env::temp_dir().join(format!(
			"rooms-archive-rust-{}-{}",
			std::process::id(),
			NEXT.fetch_add(1, Ordering::Relaxed)
		));
		fs::create_dir(&path).unwrap();
		Self(path)
	}
	pub(super) fn file(&self) -> PathBuf {
		self.0.join(disk::FILE)
	}
}
impl Drop for Temp {
	fn drop(&mut self) {
		fs::remove_dir_all(&self.0).unwrap();
	}
}
pub(super) fn record(id: &str, text: DocumentText, at: u64) -> Record {
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
			text,
			mine: false,
			at,
			order: at,
			state: LineState::Present,
			previews: Default::default(),
			attachments: vec![],
		},
	)
	.unwrap()
}
#[tokio::test]
async fn journal_preserves_captured_state_and_repairs_only_the_torn_tail() {
	let fixture: serde_json::Value =
		serde_json::from_str(include_str!("../../../../proofs/fixtures/archive-disk.json")).unwrap();
	for case in fixture["cases"].as_array().unwrap() {
		let temp = Temp::new();
		let original = case["input"].as_str().unwrap().as_bytes();
		fs::write(temp.file(), original).unwrap();
		#[cfg(unix)]
		{
			use std::os::unix::fs::PermissionsExt;
			fs::set_permissions(&temp.0, fs::Permissions::from_mode(0o755)).unwrap();
		}
		let opened = FileArchive::open(
			&temp.0,
			Options {
				capacity: 3,
				compact_delta: 2,
				..Default::default()
			},
		)
		.await;
		assert_eq!(opened.is_ok(), case["valid"].as_bool().unwrap());
		if let Ok(mut archive) = opened {
			#[cfg(unix)]
			{
				use std::os::unix::fs::PermissionsExt;
				assert_eq!(fs::metadata(&temp.0).unwrap().permissions().mode() & 0o777, 0o700);
			}
			assert!(FileArchive::open(&temp.0, Options::default()).await.is_err());
			let page = archive.read(&Filter::default(), 0, 128).await.unwrap();
			assert_eq!(page.next, case["next"].as_u64().unwrap());
			let repaired = fs::read(temp.file()).unwrap();
			assert_eq!(repaired != original, case["repaired"].as_bool().unwrap());
			drop(archive);
			let mut reopened = FileArchive::open(&temp.0, Options::default()).await.unwrap();
			assert_eq!(reopened.read(&Filter::default(), 0, 128).await.unwrap().next, page.next);
		} else {
			assert_eq!(fs::read(temp.file()).unwrap(), original);
		}
	}
	let temp = Temp::new();
	let options = Options {
		capacity: 2,
		compact_delta: 1,
		..Default::default()
	};
	let mut archive = FileArchive::open(&temp.0, options).await.unwrap();
	assert_eq!(archive.put(record("one", "original".into(), 10)).await.unwrap(), 1);
	assert_eq!(archive.put(record("two", "second".into(), 20)).await.unwrap(), 2);
	let held = archive.read(&Filter::default(), 0, 128).await.unwrap();
	assert!(Arc::ptr_eq(
		&held.records[0].record,
		&archive.store.lock().unwrap().index.snapshot().next().unwrap().record
	));
	assert_eq!(
		archive
			.put(record("one", DocumentText::from_utf16(&[b'x' as u16, 0xd800]), 99))
			.await
			.unwrap(),
		3
	);
	drop(archive);
	let mut archive = FileArchive::open(&temp.0, options).await.unwrap();
	let page = archive.read(&Filter::default(), 2, 128).await.unwrap();
	assert!(
		matches!(page.records[0].record.body(),Body::Line {at:10,order:10,text,..} if text.utf16().collect::<Vec<_>>()==[b'x' as u16,0xd800])
	);
	assert_eq!(archive.put(record("three", "third".into(), 30)).await.unwrap(), 4);
	assert_eq!(archive.read(&Filter::default(), 0, 128).await.unwrap().records.len(), 2);
}
#[tokio::test]
async fn replacement_can_fit_without_room_for_an_append() {
	let temp = Temp::new();
	let one = record("one", "same".into(), 1);
	let two = record("two", "same".into(), 1);
	let mut index = Index::new(1).unwrap();
	index.apply(1, one.clone()).unwrap();
	let bytes = disk::snapshot(&index, disk::MAX_FILE_BYTES).unwrap().byte_len();
	let options = Options {
		capacity: 1,
		max_file_bytes: bytes,
		..Default::default()
	};
	let mut archive = FileArchive::open(&temp.0, options).await.unwrap();
	archive.put(one).await.unwrap();
	archive.put(two.clone()).await.unwrap();
	assert!(fs::metadata(temp.file()).unwrap().len() <= bytes as u64);
	assert_eq!(
		archive.read(&Filter::default(), 0, 128).await.unwrap().records[0]
			.record
			.as_ref(),
		&two
	);
	let prior = fs::read(temp.file()).unwrap();
	assert!(archive.put(record("big", "x".repeat(8192).into(), 1)).await.is_err());
	assert_eq!(fs::read(temp.file()).unwrap(), prior);
	drop(archive);
	let mut restored = FileArchive::open(&temp.0, options).await.unwrap();
	assert_eq!(restored.read(&Filter::default(), 0, 128).await.unwrap().next, 2);
}
#[tokio::test]
async fn cancellation_observes_the_owned_job_and_uncertain_replacement_requires_reload() {
	let temp = Temp::new();
	let mut archive = FileArchive::open(&temp.0, Options::default()).await.unwrap();
	let shared = archive.store.clone();
	let (held, ready) = std::sync::mpsc::channel();
	let (release, wait) = std::sync::mpsc::channel();
	let lock = std::thread::spawn(move || {
		let _guard = shared.lock().unwrap();
		held.send(()).unwrap();
		wait.recv().unwrap();
	});
	ready.recv().unwrap();
	assert!(
		tokio::time::timeout(
			Duration::from_millis(5),
			archive.put(record("one", "pending".into(), 1))
		)
		.await
		.is_err()
	);
	assert!(archive.pending.is_some());
	assert!(FileArchive::open(&temp.0, Options::default()).await.is_err());
	release.send(()).unwrap();
	lock.join().unwrap();
	archive.finish_pending().await.unwrap();
	assert_eq!(archive.read(&Filter::default(), 0, 128).await.unwrap().next, 1);
	// The actual rename succeeds; failure of the final directory sync leaves
	// disk potentially committed while memory must refuse further operations.
	{
		let mut store = archive.store.lock().unwrap();
		let mut proposed = Index::new(5000).unwrap();
		proposed.apply(1, record("other", "on disk".into(), 1)).unwrap();
		let snapshot = disk::snapshot(&proposed, disk::MAX_FILE_BYTES).unwrap();
		let result = storage::atomic::replace_with_sync(&store.directory, disk::FILE, snapshot.chunks(), || {
			Err(io::Error::other("injected directory sync failure"))
		});
		assert!(store.written(result).is_err());
	}
	assert!(archive.read(&Filter::default(), 0, 128).await.is_err());
	assert!(archive.put(record("three", "refused".into(), 3)).await.is_err());
	drop(archive);
	let mut restored = FileArchive::open(&temp.0, Options::default()).await.unwrap();
	assert_eq!(
		restored.read(&Filter::default(), 0, 128).await.unwrap().records[0]
			.record
			.coordinates()
			.id
			.as_str(),
		Some("other")
	);
}

#[tokio::test]
async fn unsupported_header_names_both_schemas_without_modifying_the_archive() {
	for (format, version) in [(disk::FORMAT, 2), ("renamed-rooms-member-archive", 1)] {
		let temp = Temp::new();
		let bytes = format!(
			"{}\n",
			serde_json::json!({"archive":format,"version":version,"revision":0})
		);
		fs::write(temp.file(), &bytes).unwrap();
		let error = FileArchive::open(&temp.0, Options::default()).await.err().unwrap();
		assert!(
			matches!(error, rooms_runtime::Error::Storage(_)),
			"a journal this build cannot read is the archive failing, not the request"
		);
		let error = error.to_string();
		assert!(error.contains(&format!("written as {format} version {version}")));
		assert!(error.contains(&format!("this build reads {} version 1", disk::FORMAT)));
		assert!(error.contains("remove its state directory"));
		assert_eq!(fs::read(temp.file()).unwrap(), bytes.as_bytes());
	}
	let temp = Temp::new();
	let bytes = format!(
		"{}\n",
		serde_json::json!({"archive":disk::FORMAT,"version":1,"revision":-1})
	);
	fs::write(temp.file(), &bytes).unwrap();
	assert!(
		FileArchive::open(&temp.0, Options::default())
			.await
			.err()
			.unwrap()
			.to_string()
			.contains("invalid archive header")
	);
	assert_eq!(fs::read(temp.file()).unwrap(), bytes.as_bytes());
}
