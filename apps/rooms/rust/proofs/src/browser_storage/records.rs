//! Current IndexedDB rows, atomic replacements, and stale recorders.
use rooms_application::{
	archive::{Access, Attachment, Body, ConversationKind, Coordinates, Facet, Filter, LineState, Record, blobs},
	files::{CHUNK_BYTES, FileDescription},
	text::DocumentText,
};
use rooms_browser::{
	platform::Platform,
	storage::{Archive, Database},
};
use rooms_runtime::archive::{BlobAccess, Chunk, Source};
use std::{
	future::Future,
	task::{Context, Waker},
};
use wasm_bindgen::prelude::*;
fn facet() -> Facet {
	Facet::new(Filter::default(), Access::Read).unwrap()
}
fn line(id: &str, text: DocumentText, attachments: Vec<Attachment>) -> Record {
	Record::new(
		Coordinates {
			source: "browser".into(),
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
			at: 999,
			order: 999,
			state: LineState::Edited,
			attachments,
			previews: Default::default(),
		},
	)
	.unwrap()
}
struct File {
	description: FileDescription,
}
impl Source for File {
	fn description(&self) -> &FileDescription {
		&self.description
	}
	async fn read(&self, offset: u64, maximum: usize) -> Result<Chunk, rooms_runtime::Error> {
		assert!(maximum <= CHUNK_BYTES);
		Ok((offset..offset + maximum as u64)
			.map(|n| (n % 251) as u8)
			.collect::<Vec<_>>()
			.into())
	}
}
#[wasm_bindgen]
pub async fn rooms_browser_storage_records() {
	let db = Database::open().await.unwrap();
	let mut archive = Archive::new(db.clone());
	let mut sibling = Archive::new(Database::open().await.unwrap());
	let mut platform = Platform::new().unwrap();
	let source = db.source(&mut platform).await.unwrap();
	let all = Filter::default();
	let initial = archive.read(&all, 0, 128).await.unwrap();
	assert_eq!(initial.next, 7);
	assert_eq!(initial.records.len(), 1);
	let record = &initial.records[0].record;
	let Body::Line { text, at, order, .. } = record.body() else {
		panic!("seeded line")
	};
	let exact = DocumentText::from_utf16(&[0x0061, 0xd800, 0x0062, 0xd83c, 0xdf31]);
	assert_eq!(*text, exact);
	assert_eq!((*at, *order), (11, 12));
	let reader = blobs::Reader::attachment(&facet(), record, 0).unwrap();
	let access = archive.blob_access();
	assert_eq!(
		access.read(reader.clone(), CHUNK_BYTES as u64 - 1, 4).await.unwrap(),
		vec![24, 25, 26, 27]
	);
	let attachments = blobs::files(record).unwrap().to_vec();
	let digest = attachments[0].blob().unwrap().to_owned();
	let found = archive.blob_reader(facet(), digest.clone()).await.unwrap();
	assert_eq!(access.read(found, 0, 3).await.unwrap(), vec![0, 1, 2]);
	assert_eq!(
		archive
			.put(line("seeded-line", exact.clone(), attachments))
			.await
			.unwrap(),
		8
	);
	let edited = archive.read(&all, 7, 1).await.unwrap();
	assert!(!edited.more);
	let Body::Line {
		at, order, attachments, ..
	} = edited.records[0].record.body()
	else {
		panic!("edited line")
	};
	assert_eq!((*at, *order), (11, 12));
	assert_eq!(attachments[0].blob(), Some(digest.as_str()));
	let description = FileDescription::new(
		"renamed.bin".into(),
		"application/octet-stream".into(),
		(CHUNK_BYTES + 3) as u64,
		0,
		0,
	)
	.unwrap();
	let changed = Attachment::new(
		description.name().into(),
		description.mime().into(),
		description.size() as u64,
		0,
		0,
		Some("f".repeat(64)),
	)
	.unwrap();
	let changed = line("seeded-line", exact.clone(), vec![changed]);
	archive.put(changed.clone()).await.unwrap();
	assert!(access.read(reader.clone(), 0, 3).await.is_err());
	assert_eq!(
		blobs::files(&archive.read(&all, 0, 1).await.unwrap().records[0].record).unwrap()[0].blob(),
		None
	);
	archive.put_files(changed, &[File { description }]).await.unwrap();
	assert_eq!(
		access.read(reader.clone(), CHUNK_BYTES as u64, 3).await.unwrap(),
		vec![25, 26, 27]
	);
	assert!(access.read(reader.clone(), 0, CHUNK_BYTES + 1).await.is_err());
	assert!(access.read(reader.clone(), 0, 0).await.is_err());
	assert!(
		access
			.read(reader.clone(), (CHUNK_BYTES + 3) as u64, 1)
			.await
			.unwrap()
			.is_empty()
	);

	let (a, b) = tokio::join!(
		archive.put(line("a", "first".into(), vec![])),
		sibling.put(line("b", "second".into(), vec![]))
	);
	let (a, b) = (a.unwrap(), b.unwrap());
	assert_eq!(a.abs_diff(b), 1);
	let mut page = archive.read(&all, 0, 1).await.unwrap();
	let mut count = page.records.len();
	while page.more {
		page = archive.read(&all, page.next, 1).await.unwrap();
		count += page.records.len();
	}
	assert_eq!(count, 3);
	let old = db.retention_epoch(&mut platform).await.unwrap();
	db.set_retention_epoch("fenced".into(), true).await.unwrap();
	assert!(access.read(reader, 0, 1).await.is_err());
	assert_eq!(
		sibling
			.put_retained(line("stale", "refused".into(), vec![]), old)
			.await
			.unwrap(),
		None
	);
	let empty = archive.read(&all, 0, 128).await.unwrap();
	assert!(empty.records.is_empty());
	assert_eq!(empty.next, a.max(b));
	assert_eq!(db.source(&mut platform).await.unwrap(), source);
	assert!(
		archive
			.put_retained(line("kept", exact.clone(), vec![]), "fenced".into())
			.await
			.unwrap()
			.is_some()
	);
	let mut abandoned = Box::pin(archive.put(line("abandoned", "committed".into(), vec![])));
	assert!(
		abandoned
			.as_mut()
			.poll(&mut Context::from_waker(Waker::noop()))
			.is_pending()
	);
	drop(abandoned);
	assert_eq!(archive.read(&all, 0, 128).await.unwrap().records.len(), 2);
	archive.close().await.unwrap();
	sibling.close().await.unwrap();
	let mut reopened = Archive::new(Database::open().await.unwrap());
	assert_eq!(reopened.read(&all, 0, 128).await.unwrap().records.len(), 2);
	reopened.close().await.unwrap();
}
#[wasm_bindgen]
pub async fn rooms_browser_storage_failed_write() {
	let mut archive = Archive::new(Database::open().await.unwrap());
	let files = [File {
		description: FileDescription::new("small.bin".into(), "".into(), 3, 0, 0).unwrap(),
	}];
	let attachment = Attachment::new("small.bin".into(), "".into(), 3, 0, 0, None).unwrap();
	let mut abandoned = Box::pin(archive.put_files(
		line("must-not-commit", "invalid revision".into(), vec![attachment]),
		&files,
	));
	assert!(
		abandoned
			.as_mut()
			.poll(&mut Context::from_waker(Waker::noop()))
			.is_pending()
	);
	drop(abandoned);
	// The next operation observes the failed abandoned write before acting.
	assert!(archive.read(&Filter::default(), 0, 128).await.is_err());
	archive.close().await.unwrap();
}

#[wasm_bindgen]
pub async fn rooms_browser_storage_eviction() {
	let mut archive = Archive::new(Database::open().await.unwrap());
	let oldest = archive.read(&Filter::default(), 0, 1).await.unwrap();
	assert_eq!(oldest.records[0].revision, 1);
	let reader = blobs::Reader::attachment(&facet(), &oldest.records[0].record, 0).unwrap();
	let access = archive.blob_access();
	assert_eq!(archive.put(line("last", "newest".into(), vec![])).await.unwrap(), 5001);
	assert_eq!(
		archive.read(&Filter::default(), 0, 1).await.unwrap().records[0].revision,
		2
	);
	assert!(access.read(reader, 0, 1).await.is_err());
	let last = archive.read(&Filter::default(), 5000, 1).await.unwrap();
	assert_eq!(last.next, 5001);
	assert!(!last.more);
	assert_eq!(last.records[0].record.coordinates().id.as_str(), Some("last"));
	archive.close().await.unwrap();
}
