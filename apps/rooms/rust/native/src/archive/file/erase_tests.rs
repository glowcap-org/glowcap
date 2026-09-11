use super::{
	blob_tests::{line, Bytes},
	tests::Temp,
	*,
};
use rooms_application::archive::{
	blobs::Reader,
	shares::{Command, Share},
	Access, Facet,
};
use std::{fs, io};
#[tokio::test]
async fn erase_keeps_cursors_and_shares_while_retiring_bytes_and_readers() {
	let temp = Temp::new();
	let mut archive = FileArchive::open(&temp.0, Options::default()).await.unwrap();
	let sources = [Bytes::new(b"private".to_vec())];
	archive.put_with_files(line("one", &sources), &sources).await.unwrap();
	let spec = Share::new(
		"12345678-1234-4234-8234-123456789abc".into(),
		"Garden".into(),
		Filter::default(),
	)
	.unwrap();
	archive.change_share(Command::Issue(spec.clone())).await.unwrap();
	let page = archive.read(&Filter::default(), 0, 128).await.unwrap();
	let reader = Reader::attachment(
		&Facet::new(Filter::default(), Access::Read).unwrap(),
		&page.records[0].record,
		0,
	)
	.unwrap();
	archive.clear().await.unwrap();
	assert!(archive.read_blob(reader, 0, 7).await.is_err());
	assert_eq!(archive.blob_usage().await.unwrap(), BlobUsage::default());
	assert_eq!(archive.active_shares().await.unwrap(), vec![spec.clone()]);
	assert_eq!(fs::read_dir(temp.0.join("blobs")).unwrap().count(), 0);
	let empty = archive.read(&Filter::default(), page.next, 128).await.unwrap();
	assert_eq!(empty.next, page.next);
	assert!(empty.records.is_empty());
	drop(archive);
	let mut archive = FileArchive::open(&temp.0, Options::default()).await.unwrap();
	assert_eq!(archive.active_shares().await.unwrap(), vec![spec]);
	assert_eq!(archive.put(tests::record("later", "new".into(), 2)).await.unwrap(), 2);
	assert_eq!(
		archive
			.read(&Filter::default(), page.next, 128)
			.await
			.unwrap()
			.records
			.len(),
		1
	);
}
#[tokio::test]
async fn failed_byte_cleanup_does_not_restore_erased_records_and_clear_retries_it() {
	let temp = Temp::new();
	let mut archive = FileArchive::open(&temp.0, Options::default()).await.unwrap();
	let sources = [Bytes::new(b"private".to_vec())];
	archive.put_with_files(line("one", &sources), &sources).await.unwrap();
	let path = temp.0.join("blobs");
	let moved = temp.0.join("held-blobs");
	fs::rename(&path, &moved).unwrap();
	fs::write(&path, b"make child access fail").unwrap();
	assert!(archive.clear().await.unwrap_err().contains("records erased"));
	let page = archive.read(&Filter::default(), 0, 128).await.unwrap();
	assert!(page.records.is_empty());
	assert_eq!(page.next, 1);
	let usage = archive.blob_usage().await.unwrap();
	assert_eq!(usage.retained_bytes, 0);
	assert_eq!(usage.orphan_bytes, 7);
	assert_eq!(usage.pending_files, 1);
	let committed = fs::read(temp.file()).unwrap();
	fs::remove_file(&path).unwrap();
	fs::rename(&moved, &path).unwrap();
	archive.clear().await.unwrap();
	assert_eq!(fs::read(temp.file()).unwrap(), committed);
	assert_eq!(archive.blob_usage().await.unwrap(), BlobUsage::default());
}
#[tokio::test]
async fn uncertain_erase_keeps_bytes_until_the_committed_journal_is_recovered() {
	let temp = Temp::new();
	let mut archive = FileArchive::open(&temp.0, Options::default()).await.unwrap();
	let sources = [Bytes::new(b"private".to_vec())];
	archive.put_with_files(line("one", &sources), &sources).await.unwrap();
	let backup = temp.0.join("saved-journal");
	fs::rename(temp.file(), &backup).unwrap();
	fs::create_dir(temp.file()).unwrap();
	assert!(archive.clear().await.unwrap_err().contains("reload required"));
	assert_eq!(fs::read_dir(temp.0.join("blobs")).unwrap().count(), 1);
	assert!(archive.read(&Filter::default(), 0, 128).await.is_err());
	fs::remove_dir(temp.file()).unwrap();
	fs::rename(&backup, temp.file()).unwrap();
	drop(archive);
	let mut archive = FileArchive::open(&temp.0, Options::default()).await.unwrap();
	assert_eq!(archive.read(&Filter::default(), 0, 128).await.unwrap().records.len(), 1);
	// The other uncertain outcome: rename really committed an empty journal,
	// but its final directory sync failed. Old memory and blobs stay untouched.
	{
		let mut store = archive.store.lock().unwrap();
		let mut empty = Index::new(5000).unwrap();
		empty.restore(store.index.revision(), Vec::new()).unwrap();
		let snapshot = disk::snapshot(&empty, disk::MAX_FILE_BYTES).unwrap();
		let written = storage::atomic::replace_with_sync(&store.directory, disk::FILE, snapshot.chunks(), || {
			Err(io::Error::other("injected erase directory sync failure"))
		});
		assert!(store.written(written).is_err());
		assert_eq!(store.index.len(), 1);
		assert_eq!(store.blobs.as_ref().unwrap().usage().retained_bytes, 7);
	}
	drop(archive);
	let mut archive = FileArchive::open(&temp.0, Options::default()).await.unwrap();
	let empty = archive.read(&Filter::default(), 0, 128).await.unwrap();
	assert_eq!(empty.next, 1);
	assert!(empty.records.is_empty());
	assert_eq!(archive.blob_usage().await.unwrap(), BlobUsage::default());
}
