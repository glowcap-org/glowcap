//! Retention as values: the tail per room, the global edges, the exact-row
//! edits, and the row and file forms shared with the TypeScript owner.
use super::*;
use alloc::{format, vec};

fn line(from: &str, text: &str, at: u64) -> KeptLine {
	KeptLine {
		from: from.into(),
		text: text.into(),
		at,
	}
}

#[test]
fn a_room_keeps_its_last_lines_and_persists_each_append() {
	let mut index = Index::default();
	let (token, persist) = index.record("Garden", line("alice", "hi", 1)).unwrap();
	assert_eq!(
		persist,
		Persist::Append {
			room: "Garden".into(),
			line: Arc::new(line("alice", "hi", 1)),
			evicted: None
		}
	);
	for n in 0..LINES_KEPT {
		index
			.record("garden", line("bob", &n.to_string(), 2 + n as u64))
			.unwrap();
	}
	assert_eq!(index.lines(), LINES_KEPT);
	assert_eq!(index.read("GARDEN", 2).len(), 2);
	assert_eq!(index.read("Garden", 1000).len(), LINES_KEPT);
	assert_eq!(index.read("Garden", 1000)[0].text, "0", "the first line fell off");
	// The dropped row's token names nothing any more.
	assert_eq!(index.forget("Garden", token), None);
}

#[test]
fn edits_and_withdrawals_touch_the_exact_row_and_replace_the_tail() {
	let mut index = Index::default();
	let (first, _) = index.record("Garden", line("alice", "one", 1)).unwrap();
	let (second, _) = index.record("Garden", line("alice", "two", 2)).unwrap();
	let updated = index.update("Garden", first, "uno").unwrap().unwrap();
	assert_eq!(
		updated,
		Persist::Replace {
			room: "Garden".into(),
			tail: vec![Arc::new(line("alice", "uno", 1)), Arc::new(line("alice", "two", 2))]
		}
	);
	assert!(index.update("Garden", first, &"x".repeat(MAX_LINE_BYTES + 1)).is_err());
	assert_eq!(index.update("Elsewhere", first, "x").unwrap(), None);
	let forgotten = index.forget("garden", second).unwrap();
	assert_eq!(
		forgotten,
		Persist::Replace {
			room: "garden".into(),
			tail: vec![Arc::new(line("alice", "uno", 1))]
		}
	);
	let emptied = index.forget("Garden", first).unwrap();
	assert_eq!(
		emptied,
		Persist::Replace {
			room: "Garden".into(),
			tail: vec![]
		}
	);
	assert_eq!(index.rooms(), 0);
	assert_eq!(index.lines(), 0);
}

#[test]
fn the_server_evicts_the_oldest_room_whole_at_its_edges() {
	let mut index = Index::default();
	for n in 0..ROOMS_KEPT {
		index.record(&format!("r{n:03}"), line("a", "x", n as u64)).unwrap();
	}
	let (_, persist) = index.record("newest", line("a", "x", 1000)).unwrap();
	assert_eq!(
		persist,
		Persist::Append {
			room: "newest".into(),
			line: Arc::new(line("a", "x", 1000)),
			evicted: Some("r000".into())
		}
	);
	assert_eq!(index.rooms(), ROOMS_KEPT);
	// The line ceiling evicts too: fill one room past its share of the total.
	let mut index = Index::default();
	for room in 0..9 {
		for n in 0..LINES_KEPT {
			index
				.record(&format!("room{room}"), line("a", "x", (room * LINES_KEPT + n) as u64))
				.unwrap();
		}
	}
	assert!(index.lines() <= LINES_KEPT_TOTAL);
	assert_eq!(index.read("room0", 1).len(), 0, "the oldest room left whole");
}

#[test]
fn a_restore_trims_validates_and_names_what_it_evicted() {
	let mut index = Index::default();
	let mut lines: Vec<KeptLine> = (0..LINES_KEPT + 5)
		.map(|n| line("a", &n.to_string(), n as u64))
		.collect();
	index.restore_room("Garden", lines.clone()).unwrap();
	assert_eq!(index.read("Garden", 1000).len(), LINES_KEPT);
	assert_eq!(index.restore_room("garden", vec![]).unwrap_err(), Error::Repeated);
	lines[0].from = String::new();
	assert_eq!(index.restore_room("Other", lines).unwrap_err(), Error::Line);
	assert_eq!(index.restore_room("", vec![]).unwrap_err(), Error::RoomName);
	let mut index = Index::default();
	for n in 0..ROOM_FILES {
		index
			.restore_room(&format!("r{n:03}"), vec![line("a", "x", n as u64)])
			.unwrap();
	}
	assert_eq!(index.take_evicted(), vec!["r000".to_string()]);
	assert!(index.take_evicted().is_empty());
	// A restored row has no token, so no line capability governs it.
	assert_eq!(index.forget("r001", Token(0)), None);
}

#[test]
fn rows_and_file_names_are_the_typescript_owner_forms() {
	let encoded = encode_line(&line("alice", "hi \"there\"", 7));
	assert_eq!(encoded, r#"{"version":1,"from":"alice","text":"hi \"there\"","at":7}"#);
	assert_eq!(decode_line(&encoded).unwrap(), line("alice", "hi \"there\"", 7));
	assert_eq!(decode_line("{").unwrap_err(), Error::Json);
	assert_eq!(
		decode_line(r#"{"version":2,"from":"a","text":"x","at":1}"#).unwrap_err(),
		Error::Version
	);
	assert_eq!(
		decode_line(r#"{"version":1,"from":"","text":"x","at":1}"#).unwrap_err(),
		Error::Line
	);
	assert_eq!(
		decode_line(r#"{"version":1,"from":"a","text":"x","at":1,"extra":true}"#).unwrap_err(),
		Error::Line
	);
	assert_eq!(file_name("Garden"), "Garden.jsonl");
	assert_eq!(file_name("~0000/x y"), "~0000%2Fx%20y.jsonl");
	assert_eq!(file_name("café!"), "caf%C3%A9!.jsonl");
	assert_eq!(room_of_file("caf%C3%A9!.jsonl").as_deref(), Some("café!"));
	assert_eq!(room_of_file("~0000%2Fx%20y.jsonl").as_deref(), Some("~0000/x y"));
	assert_eq!(room_of_file("caf%c3%a9!.jsonl"), None, "not canonical");
	assert_eq!(room_of_file("plain.txt"), None);
	assert_eq!(room_of_file("bad%zz.jsonl"), None);
}

#[test]
fn queued_replacements_share_unchanged_rows_and_preserve_earlier_values() {
	let mut index = Index::default();
	let (first, _) = index.record("Garden", line("a", "one", 1)).unwrap();
	index.record("Garden", line("b", "two", 2)).unwrap();
	let Some(Persist::Replace { tail: earlier, .. }) = index.update("Garden", first, "uno").unwrap() else {
		panic!("replacement");
	};
	let Some(Persist::Replace { tail: later, .. }) = index.update("Garden", first, "eins").unwrap() else {
		panic!("replacement");
	};
	assert_eq!(earlier[0].text, "uno");
	assert_eq!(later[0].text, "eins");
	assert!(!Arc::ptr_eq(&earlier[0], &later[0]));
	assert!(
		Arc::ptr_eq(&earlier[1], &later[1]),
		"unchanged text is not recopied per queued edit"
	);
}
