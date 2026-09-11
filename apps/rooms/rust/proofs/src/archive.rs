//! Existing TypeScript wire captures plus index/authority invariants, executed
//! unchanged in the native and browser Wasm migration contract.
use crate::arguments::{from_fixture, Arg};
use rooms_application::archive::{
	index::{Entry, Index, Page, Scan},
	output::{self, Output},
	protocol, Access, Body, ConversationKind, Coordinates, Facet, Filter, Kind, LineState, Record, ShareKind,
};
use std::{cell::Cell, rc::Rc, sync::Arc};
pub(super) struct Passables;
impl Output for Passables {
	type Value = Arg;
	fn text(v: &str) -> Arg {
		Arg::Text(v.into())
	}
	fn integer(v: u64) -> Arg {
		Arg::Integer(v.into())
	}
	fn boolean(v: bool) -> Arg {
		Arg::Boolean(v)
	}
	fn null() -> Arg {
		Arg::Null
	}
	fn list(v: Vec<Arg>) -> Arg {
		Arg::List(v)
	}
}
fn json(arg: &Arg) -> serde_json::Value {
	use serde_json::{json, Value};
	match arg {
		Arg::Text(v) => json!(v),
		Arg::Integer(v) => json!({"integer":v.to_string()}),
		Arg::Boolean(v) => json!(v),
		Arg::Null => Value::Null,
		Arg::List(v) => Value::Array(v.iter().map(json).collect()),
		_ => panic!("unexpected output"),
	}
}
fn line(directory: &str, conversation: &str, text: &str, at: u64) -> Record {
	Record::new(
		Coordinates {
			source: "source".into(),
			generation: "generation".into(),
			id: "same-id".into(),
		},
		directory.into(),
		Body::Line {
			conversation_kind: ConversationKind::Room,
			conversation: conversation.into(),
			from: "alice".into(),
			text: text.into(),
			mine: false,
			at,
			order: at,
			state: LineState::Present,
			attachments: vec![],
		},
	)
	.unwrap()
}
pub fn run() {
	wire_projection();
	let fixture: serde_json::Value = serde_json::from_str(include_str!("../fixtures/archive.json")).unwrap();
	for case in fixture["records"].as_array().unwrap() {
		let arg = from_fixture(&case["input"]);
		let parsed = protocol::record(&&arg);
		assert_eq!(
			parsed.is_ok(),
			case["valid"].as_bool().unwrap(),
			"record {}",
			case["input"]
		);
		if let Ok(record) = parsed {
			let row = Arg::List(output::record::<Passables>(&record));
			assert_eq!(json(&row), case["output"]);
			assert_eq!(protocol::record(&&row).unwrap(), record);
		}
	}
	for case in fixture["filters"].as_array().unwrap() {
		let arg = from_fixture(&case["input"]);
		let parsed = protocol::filter(&&arg);
		assert_eq!(
			parsed.is_ok(),
			case["valid"].as_bool().unwrap(),
			"filter {}",
			case["input"]
		);
		if let Ok(filter) = parsed {
			assert_eq!(json(&output::filter::<Passables>(&filter).unwrap()), case["output"]);
		}
	}
	for at in 0..14 {
		let drops = Rc::new(Cell::new(0));
		let mut row = output::record::<Passables>(&line("dir", "garden", "hello", 1));
		row[at] = Arg::Capability(drops.clone());
		let row = Arg::List(row);
		assert!(protocol::record(&&row).is_err());
		assert_eq!(drops.get(), 0); // Parsing borrows; the binding owns disposal.
		drop(row);
		assert_eq!(drops.get(), 1);
	}
	for n in [1, 128, 129, i128::MAX] {
		assert_eq!(protocol::read_limit(&Arg::Integer(n)).unwrap(), n.min(128) as usize);
	}
	for value in [Arg::Integer(0), Arg::Integer(-1), Arg::Float(1.0), Arg::Null] {
		assert!(protocol::read_limit(&value).is_err());
	}
	index();
	scopes();
	scan();
	identities();
}
fn index() {
	let all = Filter::default();
	assert!(Index::new(0).is_err());
	assert!(Index::new(5001).is_err());
	let mut index = Index::new(3).unwrap();
	let garden = line("dir", "garden", "first", 10);
	index.apply(1, garden.clone()).unwrap();
	index.apply(2, line("dir", "library", "sibling room", 20)).unwrap();
	index
		.apply(3, line("other-dir", "garden", "sibling directory", 30))
		.unwrap();
	let held = index.read(&all, 0, 1).unwrap();
	assert!(held.more);
	assert_eq!(held.next, 1);
	assert_eq!(index.retired_by(&garden), Some(&garden));
	assert_eq!(
		index.apply(4, line("dir", "garden", "edited", 99)).unwrap().as_deref(),
		Some(&garden)
	);
	assert_eq!(index.len(), 3);
	assert_eq!(held.records[0].record.as_ref(), &garden); // A held page is immutable.
	let page = index.read(&all, 1, 128).unwrap();
	assert_eq!(page.records.iter().map(|e| e.revision).collect::<Vec<_>>(), [2, 3, 4]);
	assert!(
		matches!(page.records[2].record.body(), Body::Line { at:10, order:10, text, .. } if text.as_str()==Some("edited"))
	);
	let row = output::page::<Passables>(&page, &all, 1, 128).unwrap();
	let parsed = protocol::page(&&row, &all, 1, 128).unwrap();
	assert_eq!(parsed.next, 4);
	assert!(!parsed.more);
	assert!(protocol::page(&&row, &all, 4, 128).is_err());
	assert!(protocol::page(&&row, &all, 1, 2).is_err());
	let next = line("dir", "new-room", "new", 50);
	assert_eq!(
		index.retired_by(&next).unwrap().conversation().as_str(),
		Some("library")
	);
	let retired = index.apply(5, next).unwrap().unwrap();
	assert_eq!(retired.conversation().as_str(), Some("library"));
	assert!(index.apply(7, garden.clone()).is_err());
	assert_eq!(index.revision(), 5);
	let ahead = index.read(&all, 100, 128).unwrap();
	assert_eq!(ahead.next, 100);
	assert!(!ahead.more);
	assert!(ahead.records.is_empty());
	ahead.validate(&all, 100, 128).unwrap();
	let saved = index
		.snapshot()
		.map(|e| Entry {
			revision: e.revision,
			record: e.record.clone(),
		})
		.collect();
	let mut restored = Index::new(3).unwrap();
	restored.restore(5, saved).unwrap();
	assert_eq!(restored.len(), 3);
	for revisions in [[1, 2], [2, 1], [1, 6]] {
		assert!(restored
			.restore(
				5,
				revisions
					.map(|revision| Entry {
						revision,
						record: Arc::new(garden.clone())
					})
					.into()
			)
			.is_err());
		assert_eq!(restored.revision(), 5);
		assert_eq!(restored.len(), 3);
	}
	restored.clear();
	assert_eq!(restored.revision(), 5);
	assert!(restored.is_empty());
	restored.apply(6, garden).unwrap();
	let mut invalid = restored.read(&all, 0, 1).unwrap();
	invalid.more = true;
	invalid.next = 7;
	assert!(invalid.validate(&all, 0, 1).is_err());
	invalid.next = 6;
	invalid.validate(&all, 0, 1).unwrap();
	invalid.records.push(invalid.records[0].clone());
	assert!(invalid.validate(&all, 0, 2).is_err());
}
fn scopes() {
	let root = Facet::new(Filter::default(), Access::ReadWrite).unwrap();
	let asked = Filter::shared(ShareKind::Room, "dir".into(), Some("garden".into())).unwrap();
	let facet = root.narrow(&asked, Access::ReadWrite).unwrap();
	assert!(facet.permits_put(&line("dir", "garden", "yes", 1)));
	assert!(!facet.permits_put(&line("dir", "library", "no", 1)));
	assert!(!facet.permits_put(&line("other", "garden", "no", 1)));
	let read = facet.narrow(&Filter::default(), Access::Read).unwrap();
	assert_eq!(read.scope(), &asked);
	assert!(!read.permits_put(&line("dir", "garden", "no", 1)));
	assert!(read.narrow(&Filter::default(), Access::ReadWrite).is_err());
	let other = Filter {
		conversation: Some("library".into()),
		..Default::default()
	};
	assert!(facet.narrow(&other, Access::Read).is_err());
	assert!(asked.intersect(&other).is_none());
	let standing = Filter {
		kind: Some(Kind::Standing),
		..Default::default()
	};
	assert!(standing.intersect(&asked).is_none());
	let direct = Filter::shared(ShareKind::Direct, "dir".into(), Some("garden".into())).unwrap();
	assert!(!direct.matches(&line("dir", "garden", "no", 1)));
	assert!(Filter::shared(ShareKind::Direct, "dir".into(), None).is_err());
	assert!(Filter::shared(ShareKind::Standing, "dir".into(), None).is_ok());
}

fn scan() {
	let original = Arc::new(line("dir", "garden", "old", 1));
	let weak = Arc::downgrade(&original);
	let mut scan = Scan::new(Filter::default()).unwrap();
	let page = |after: u64, count: usize, more: bool, record: Arc<Record>| Page {
		next: after + count as u64,
		more,
		records: (1..=count)
			.map(|offset| {
				Arc::new(Entry {
					revision: after + offset as u64,
					record: record.clone(),
				})
			})
			.collect(),
	};
	scan.push(page(0, 128, true, original)).unwrap();
	assert!(weak.upgrade().is_some());
	let latest = Arc::new(line("dir", "garden", "new", 2));
	scan.push(page(128, 128, true, latest.clone())).unwrap();
	assert!(weak.upgrade().is_none()); // Neither map values nor keys retain old text.
	for _ in 2..39 {
		scan.push(page(scan.after(), 128, true, latest.clone())).unwrap();
	}
	assert_eq!(scan.after(), 4992);
	assert!(scan.push(page(4992, 128, true, latest.clone())).is_err());
	assert_eq!(scan.after(), 4992); // Refusal preserves the accepted prefix.
	scan.push(page(4992, 8, false, latest)).unwrap();
	assert!(scan.is_complete());
	assert!(scan
		.push(Page {
			next: 5000,
			more: false,
			records: vec![]
		})
		.is_err());
	let result = scan.finish().unwrap();
	assert_eq!(result.len(), 1);
	assert_eq!(result[0].revision, 5000);
	assert!(Scan::new(Filter::default()).unwrap().finish().is_err());
}

fn identities() {
	let first = line("dir", "garden", "first", 1);
	let mut variants = vec![
		first.clone(),
		line("other", "garden", "other directory", 1),
		line("dir", "library", "other room", 1),
	];
	for field in 0..3 {
		let mut coordinates = first.coordinates().clone();
		match field {
			0 => coordinates.source = "other".into(),
			1 => coordinates.generation = "other".into(),
			_ => coordinates.id = "other".into(),
		}
		variants.push(Record::new(coordinates, "dir".into(), first.body().clone()).unwrap());
	}
	let mut direct = first.body().clone();
	if let Body::Line { conversation_kind, .. } = &mut direct {
		*conversation_kind = ConversationKind::Direct;
	}
	variants.push(Record::new(first.coordinates().clone(), "dir".into(), direct).unwrap());
	variants.push(
		Record::new(
			first.coordinates().clone(),
			"dir".into(),
			Body::Standing {
				room: "garden".into(),
				nick: "alice".into(),
				at: 1,
			},
		)
		.unwrap(),
	);
	let mut index = Index::new(8).unwrap();
	for (offset, record) in variants.iter().enumerate() {
		index.apply(offset as u64 + 1, record.clone()).unwrap();
	}
	assert_eq!(index.len(), 8);
	for record in &variants {
		assert_eq!(index.retired_by(record), Some(record));
	}
	index.apply(9, line("dir", "garden", "changed", 2)).unwrap();
	assert_eq!(index.len(), 8);
	for filter in [
		Filter {
			source: Some("other".into()),
			..Default::default()
		},
		Filter {
			generation: Some("other".into()),
			..Default::default()
		},
		Filter {
			kind: Some(Kind::Standing),
			..Default::default()
		},
		Filter {
			conversation_kind: Some(ConversationKind::Direct),
			..Default::default()
		},
	] {
		let page = index.read(&filter, 0, 128).unwrap();
		assert_eq!(page.records.len(), 1);
		page.validate(&filter, 0, 128).unwrap();
	}
}

fn wire_projection() {
	use rooms_application::room::ArgumentView;
	let record: Record = serde_json::from_str(r#"{"kind":"line","source":"source","generation":"generation","id":"\ud800","directory":"directory","conversationKind":"room","conversation":"garden","from":"alice","text":"a\ud801b","mine":false,"at":1,"order":1,"state":"present","attachments":[{"name":"\ud802","mime":"text/plain","size":1,"width":0,"height":0,"blob":null}]}"#).unwrap();
	let row = output::record::<Passables>(&record);
	assert_eq!(row[3].text(), Some("�"));
	assert_eq!(row[8].text(), Some("a�b"));
	let Arg::List(files) = &row[13] else { panic!("files") };
	let Arg::List(file) = &files[0] else { panic!("file") };
	assert_eq!(file[0].text(), Some("�"));
	assert_eq!(record.coordinates().id.utf16().collect::<Vec<_>>(), [0xd800]);
	let Body::Line { text, attachments, .. } = record.body() else {
		panic!("line")
	};
	assert_eq!(text.utf16().collect::<Vec<_>>(), [0x61, 0xd801, 0x62]);
	assert_eq!(attachments[0].name().utf16().collect::<Vec<_>>(), [0xd802]);
}
