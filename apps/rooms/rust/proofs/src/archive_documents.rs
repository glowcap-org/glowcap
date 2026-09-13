//! The archive record document as this runtime writes it, pinned to a file the
//! page reads. The browser projection and the disk archive both hand records
//! over as these documents, and the page parses them into its own record
//! type, so the field names are a contract between two languages. The fixture
//! is that contract written down: every document in it must read back through
//! the serde reader and write out again as exactly the same JSON, and the page
//! side reads the same file in `apps/rooms/test/archive/record_document_test.ts`.
//! A field renamed on either side turns one of the two readers red.
use rooms_application::archive::{Body, Record};

pub fn run() {
	let fixture: serde_json::Value =
		serde_json::from_str(include_str!("../fixtures/archive-record-documents.json")).unwrap();
	let documents = fixture["documents"].as_array().unwrap();
	let mut previews = 0;
	let mut blobs = 0;
	for document in documents {
		// From text, as the disk archive and the projection read it: the blob
		// digest is taken as a raw value, which serde offers only from a string.
		let record: Record = serde_json::from_str(&document.to_string()).unwrap();
		assert_eq!(
			serde_json::to_value(&record).unwrap(),
			*document,
			"the runtime writes a record document differently from the fixture it reads"
		);
		if let Body::Line {
			previews: kept,
			attachments,
			..
		} = record.body()
		{
			previews += kept.urls().len();
			blobs += attachments.iter().filter(|a| a.blob().is_some()).count();
		}
	}
	// The fixture has to exercise the fields a rename would hide: a kept link
	// preview and an attachment with its bytes' digest.
	assert!(previews > 0, "no fixture line keeps a link preview");
	assert!(blobs > 0, "no fixture attachment carries a blob digest");
}
