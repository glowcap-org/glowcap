//! Disk captures are independent TypeScript outcomes. Explicit UTF-16 vectors
//! prevent a lossy decoder and encoder from agreeing on the same damaged text.
use rooms_application::{
	archive::{self, disk, index::Index, Attachment, Body, ConversationKind, Coordinates, Filter, LineState, Record},
	text::DocumentText,
};
use serde_json::Value;
fn bytes(snapshot: disk::Snapshot) -> Vec<u8> {
	snapshot.into_chunks().into_iter().flatten().collect()
}
pub fn run() {
	let fixture: Value = serde_json::from_str(include_str!("../fixtures/archive-disk.json")).unwrap();
	for case in fixture["cases"].as_array().unwrap() {
		let input = case["input"].as_str().unwrap();
		let restored = disk::recover(input.as_bytes(), 3, 2, disk::MAX_FILE_BYTES);
		assert_eq!(restored.is_ok(), case["valid"].as_bool().unwrap(), "{}", input);
		if let Ok(restored) = restored {
			assert_eq!(restored.index.revision(), case["next"].as_u64().unwrap());
			assert_eq!(restored.repair_tail, case["repaired"].as_bool().unwrap());
			let expected = case["records"].as_array().unwrap();
			assert_eq!(restored.index.len(), expected.len());
			for (entry, expected) in restored.index.snapshot().zip(expected) {
				let record: Record = serde_json::from_str(expected["json"].as_str().unwrap()).unwrap();
				assert_eq!(entry.record.as_ref(), &record);
				assert_eq!(entry.revision, expected["revision"].as_u64().unwrap());
				assert_eq!(
					serde_json::json!(entry.record.coordinates().id.utf16().collect::<Vec<_>>()),
					expected["id"]
				);
				if let Body::Line { text, attachments, .. } = entry.record.body() {
					assert_eq!(serde_json::json!(text.utf16().collect::<Vec<_>>()), expected["text"]);
					if let Some(file) = attachments.first() {
						assert_eq!(
							serde_json::json!(file.name().utf16().collect::<Vec<_>>()),
							expected["name"]
						);
					}
				}
			}
			let snapshot = disk::snapshot(&restored.index, disk::MAX_FILE_BYTES).unwrap();
			assert_eq!(snapshot.chunks().map(<[u8]>::len).sum::<usize>(), snapshot.byte_len());
			let encoded = bytes(snapshot);
			let again = disk::recover(&encoded, 3, 2, disk::MAX_FILE_BYTES).unwrap();
			assert!(!again.repair_tail);
			assert_eq!(again.index.revision(), restored.index.revision());
			for (a, b) in again.index.snapshot().zip(restored.index.snapshot()) {
				assert_eq!(a.record, b.record);
				assert_eq!(a.revision, b.revision);
			}
			assert!(disk::snapshot(&restored.index, encoded.len() - 1).is_err());
		}
	}
	preparation();
	let index = Index::new(3).unwrap();
	let mut damaged = bytes(disk::snapshot(&index, 1024).unwrap());
	damaged.extend_from_slice(b"\xff");
	assert!(disk::recover(&damaged, 3, 2, 1024).unwrap().repair_tail);
	damaged.push(b'\n');
	assert!(disk::recover(&damaged, 3, 2, 1024).is_err());
}
fn record(id: DocumentText, name: &str, digest: &str, at: u64) -> Record {
	Record::new(
		Coordinates {
			source: "source".into(),
			generation: "generation".into(),
			id,
		},
		"directory".into(),
		Body::Line {
			conversation_kind: ConversationKind::Room,
			conversation: "garden".into(),
			from: "alice".into(),
			text: "hello".into(),
			mine: false,
			at,
			order: at,
			state: LineState::Present,
			attachments: vec![Attachment::new(name.into(), "text/plain".into(), 1, 0, 0, Some(digest.into())).unwrap()],
		},
	)
	.unwrap()
}
fn preparation() {
	let a = "a".repeat(64);
	let b = "b".repeat(64);
	let mut index = Index::new(2).unwrap();
	let first = record("one".into(), "file", &a, 10);
	index.apply(1, first.clone()).unwrap();
	let mut bytes = bytes(disk::snapshot(&index, 10000).unwrap());
	let prepared = index.prepare_put(record("one".into(), "file", &b, 99));
	assert!(
		matches!(prepared.body(),Body::Line {at:10,order:10,attachments,..} if attachments[0].blob()==Some(a.as_str()))
	);
	assert_eq!(index.revision(), 1);
	assert_eq!(index.get(&first), Some(&first));
	bytes.extend(disk::revision(2, &prepared, 10000).unwrap());
	let restored = disk::recover(&bytes, 2, 2, 10000).unwrap();
	assert_eq!(restored.index.get(&first), Some(&prepared));
	for submitted in [
		record("one".into(), "changed", &b, 99),
		record("other".into(), "file", &b, 99),
	] {
		let prepared = index.prepare_put(submitted);
		assert!(matches!(prepared.body(),Body::Line {attachments,..} if attachments[0].blob().is_none()));
	}
	// Different isolated surrogates must never collapse to one storage identity.
	let one = DocumentText::from_utf16(&[0xd800]);
	let two = DocumentText::from_utf16(&[0xd801]);
	let mut index = Index::new(2).unwrap();
	index.apply(1, record(one.clone(), "file", &a, 1)).unwrap();
	index.apply(2, record(two, "file", &a, 2)).unwrap();
	assert_eq!(index.len(), 2);
	let scope = Filter {
		source: Some("source".into()),
		..Default::default()
	};
	assert_eq!(index.read(&scope, 0, 128).unwrap().records.len(), 2);
	assert_eq!(
		index
			.get(&record(one, "file", &a, 1))
			.unwrap()
			.coordinates()
			.id
			.utf16()
			.collect::<Vec<_>>(),
		[0xd800]
	);
	assert!(archive::disk::revision(0, &first, 10000).is_err());
}
