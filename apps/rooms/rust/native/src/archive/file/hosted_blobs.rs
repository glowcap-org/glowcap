//! Real source callbacks and archived byte readers share bounded admission. Releasing readers does not replenish their caller's mint budget.
use super::*;
use crate::client::Deadline;
use glowcap::Argument;
use rooms_application::{
	archive::{blobs, Access, Attachment, Body},
	files::{FileDescription, CHUNK_BYTES},
	room::attachment::Attachment as LiveAttachment,
};
use rooms_glowcap::client::{archive::Archive as ClientArchive, Client};
use std::{cell::Cell, rc::Rc};
pub(super) async fn run(archive: &ClientArchive<Deadline>, client: &Client<Deadline>) -> u64 {
	let calls = Rc::new(Cell::new(0));
	let observed = calls.clone();
	let bytes: Rc<[u8]> = (0..CHUNK_BYTES + 3).map(|n| (n % 251) as u8).collect::<Vec<_>>().into();
	let served = bytes.clone();
	let source = client
		.session()
		.spawn_owned(move |verb, args| {
			let [Argument::Integer(offset), Argument::Integer(length)] = args else {
				return Err("source arguments".into());
			};
			if verb != "read" || *offset < 0 || *length < 1 || *length > CHUNK_BYTES as i64 {
				return Err("source bounds".into());
			}
			observed.set(observed.get() + 1);
			let start = *offset as usize;
			let end = start + *length as usize;
			Ok(Argument::Bytes(served.get(start..end).ok_or("source range")?.to_vec()))
		})
		.unwrap();
	let description = FileDescription::new("file".into(), "text/plain".into(), bytes.len() as u64, 0, 0).unwrap();
	let attachments = [LiveAttachment {
		description: description.clone(),
		blob: source.clone(),
	}];
	let plain = super::tests::record("with-files", "with files".into(), 2);
	let mut body = plain.body().clone();
	let Body::Line { attachments: files, .. } = &mut body else {
		unreachable!()
	};
	files.push(Attachment::new("file".into(), "text/plain".into(), bytes.len() as u64, 0, 0, None).unwrap());
	let record = Record::new(plain.coordinates().clone(), plain.directory().clone(), body).unwrap();
	assert_eq!(archive.put_files(&record, &attachments).await.unwrap(), 2);
	assert_eq!(calls.get(), 2);
	let read = archive.narrow(&Filter::default(), Access::Read).await.unwrap();
	assert!(read.put_files(&record, &attachments).await.is_err());
	assert_eq!(calls.get(), 2);
	let rows = archive.read_all(&Filter::default()).await.unwrap();
	let held = rows.last().unwrap().record.clone();
	let digest = blobs::files(&held).unwrap()[0].blob().unwrap();
	let blob = archive.attachment(&held, 0).await.unwrap();
	assert_eq!(blob.read(0, CHUNK_BYTES).await.unwrap(), bytes[..CHUNK_BYTES]);
	assert_eq!(
		blob.read(CHUNK_BYTES as u64, CHUNK_BYTES).await.unwrap(),
		bytes[CHUNK_BYTES..]
	);
	assert!(blob.read(bytes.len() as u64, 1).await.unwrap().is_empty());
	let by_digest = read.blob(digest).await.unwrap();
	assert_eq!(by_digest.read(0, 1).await.unwrap(), bytes[..1]);
	let other = archive
		.narrow(
			&Filter {
				conversation: Some("other".into()),
				..Default::default()
			},
			Access::Read,
		)
		.await
		.unwrap();
	assert!(other.blob(digest).await.is_err());
	assert!(client
		.session()
		.send(
			blob.reference(),
			"read",
			&[Argument::Integer(0), Argument::Integer(CHUNK_BYTES as i64 + 1)]
		)
		.await
		.is_err());
	// Two successful mints above. Every released occurrence still spends work.
	for _ in 2..blobs::MAX_READERS_PER_SESSION {
		drop(archive.attachment(&held, 0).await.unwrap());
	}
	assert!(archive.attachment(&held, 0).await.is_err());
	assert!(read.attachment(&held, 0).await.is_err());

	archive.put(&plain).await.unwrap();
	assert!(blob.read(0, 1).await.is_err());
	drop((by_digest, blob, other, read, attachments));
	client.session().release(source).unwrap();
	// putFiles, record reads and blob reads all count on the same worker.
	3
}
