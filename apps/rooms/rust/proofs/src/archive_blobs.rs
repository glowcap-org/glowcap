//! Reader authority and file admission execute unchanged in native and Wasm.
use crate::{
	archive::Passables,
	arguments::{Arg, text},
};
use rooms_application::{
	archive::{
		self, Access, Attachment, Body, ConversationKind, Coordinates, Facet, Filter, LineState, Record,
		blobs::{self, Reader, admission},
		index::Index,
		output,
	},
	files::{CHUNK_BYTES, FileDescription},
};
use std::{cell::Cell, rc::Rc};
fn line(directory: &str, name: &str, digest: &str) -> Record {
	Record::new(
		Coordinates {
			source: "source".into(),
			generation: "generation".into(),
			id: "same-id".into(),
		},
		directory.into(),
		Body::Line {
			conversation_kind: ConversationKind::Room,
			conversation: "garden".into(),
			from: "alice".into(),
			text: "line".into(),
			mine: false,
			at: 1,
			order: 1,
			state: LineState::Present,
			previews: Default::default(),
			attachments: vec![Attachment::new(name.into(), "text/plain".into(), 7, 0, 0, Some(digest.into())).unwrap()],
		},
	)
	.unwrap()
}
pub fn run() {
	let a = "a".repeat(64);
	let b = "b".repeat(64);
	let record = line("first", "file", &a);
	let metadata = &blobs::files(&record).unwrap()[0];
	let live = metadata.live_description().unwrap();
	assert!(metadata.matches_description(&live));
	let unusual = Attachment::new(
		rooms_application::text::DocumentText::from_utf16(&[0xd800]),
		"text/plain".into(),
		0,
		2,
		3,
		None,
	)
	.unwrap();
	assert!(unusual.live_description().is_err());
	assert_eq!(
		unusual.name().utf16().collect::<Vec<_>>(),
		[0xd800],
		"forwarding cannot replace document text lossily"
	);
	let facet = Facet::new(Filter::default(), Access::ReadWrite).unwrap();
	let reader = Reader::attachment(&facet, &record, 0).unwrap();
	let mut index = Index::new(2).unwrap();
	index.apply(1, record.clone()).unwrap();
	index.apply(2, line("second", "file", &b)).unwrap();
	assert_eq!(reader.resolve(&index).unwrap().blob(), Some(a.as_str()));
	assert_eq!(reader.read_length(&index, 5, CHUNK_BYTES).unwrap(), 2);
	assert_eq!(reader.read_length(&index, 10, 1).unwrap(), 0);
	assert!(reader.read_length(&index, 1 << 53, 1).is_err());
	assert!(reader.read_length(&index, 0, CHUNK_BYTES + 1).is_err());
	// Metadata can change around the same bytes. The digest is byte identity.
	index.apply(3, line("first", "renamed", &a)).unwrap();
	assert_eq!(reader.resolve(&index).unwrap().name().as_str(), Some("renamed"));
	let scoped = Facet::new(
		Filter {
			directory: Some("second".into()),
			..Default::default()
		},
		Access::Read,
	)
	.unwrap();
	assert!(Reader::attachment(&scoped, &record, 0).is_err());
	assert!(Reader::digest(&scoped, &index, &a).is_err());
	assert!(Reader::digest(&scoped, &index, &b).is_ok());
	// A backend-selected reader cannot widen the requested scope or substitute
	// another digest. Restriction follows the capability through later reads.
	assert!(reader.clone().restrict(&Filter::default(), &b).is_err());
	let restricted = reader.clone().restrict(scoped.scope(), &a).unwrap();
	assert!(restricted.resolve(&index).is_err());
	let matching = Reader::digest(&facet, &index, &b)
		.unwrap()
		.restrict(scoped.scope(), &b)
		.unwrap();
	assert_eq!(matching.resolve(&index).unwrap().blob(), Some(b.as_str()));
	assert!(
		matching
			.restrict(
				&Filter {
					directory: Some("first".into()),
					..Default::default()
				},
				&b
			)
			.is_err()
	);
	index.apply(4, line("first", "renamed", &b)).unwrap();
	assert!(reader.resolve(&index).is_err());
	index.clear();
	assert!(reader.resolve(&index).is_err());
	let wire = Arg::List(output::record::<Passables>(&record));
	let at = Arg::Integer(0);
	assert!(matches!(
		facet.admit_blob("attachment", &[&wire, &at]).unwrap(),
		admission::Request::Attachment(_)
	));
	assert!(facet.admit_blob("attachment", &[&wire, &Arg::Float(0.0)]).is_err());
	assert!(facet.admit_blob("attachment", &[&wire, &Arg::Integer(1)]).is_err());
	let cap = Rc::new(Cell::new(0));
	let args = [
		wire,
		text("file"),
		text("file"),
		text("text/plain"),
		Arg::Integer(7),
		Arg::Capability(cap.clone()),
		Arg::Integer(0),
		Arg::Integer(0),
	];
	let views = args.iter().collect::<Vec<_>>();
	let admitted = facet.admit_blob("putFiles", &views).unwrap();
	assert_eq!(Rc::strong_count(&cap), 3);
	drop(admitted);
	assert_eq!(Rc::strong_count(&cap), 2);
	let read = facet.narrow(&Filter::default(), Access::Read).unwrap();
	assert!(read.admit_blob("putFiles", &views).is_err());
	assert_eq!(Rc::strong_count(&cap), 2);
	let wrong = FileDescription::new("wrong".into(), "text/plain".into(), 7, 0, 0).unwrap();
	assert!(blobs::validate_sources(&record, core::iter::once(&wrong)).is_err());
	for (offset, length) in [
		(Arg::Float(0.0), Arg::Integer(1)),
		(Arg::Integer(-1), Arg::Integer(1)),
		(Arg::Integer(0), Arg::Integer(0)),
		(Arg::Integer(0), Arg::Integer(CHUNK_BYTES as i128 + 1)),
	] {
		assert!(admission::read("read", &[&offset, &length]).is_err());
	}
	assert_eq!(
		admission::read("read", &[Arg::Integer(0), Arg::Integer(1)]).unwrap(),
		(0, 1)
	);
	let mut budget = archive::request::MintBudget::<{ blobs::MAX_READERS_PER_SESSION }>::new();
	for _ in 0..512 {
		budget.minted().unwrap();
	}
	assert!(budget.minted().is_err());
}
