use super::*;
use crate::bot::{
	classify::{MAX_LABEL_BYTES, MAX_NAME_BYTES},
	rooms::Attachment,
};
use rooms_application::room::line::{MAX_LINE_BYTES, MAX_MESSAGE_FILES};
use rooms_testing::scratch::Scratch;

fn event(seq: u64) -> Cursor {
	Cursor::new(format!("e{seq:x}")).unwrap()
}

fn trigger(seq: u64) -> Trigger {
	Trigger {
		seq: Seq(seq),
		event: event(seq),
		line: format!("l{seq}"),
		from: None,
		text: format!("line {seq}"),
		files: Vec::new(),
	}
}

fn asked(seqs: &[u64]) -> Asked {
	Asked {
		conversation: ConversationId::new("c1"),
		kind: Kind::Direct,
		triggers: seqs.iter().map(|seq| trigger(*seq)).collect(),
	}
}

fn part(operation: &str, text: &str) -> Part {
	Part {
		operation: operation.into(),
		text: text.into(),
	}
}

fn fresh(label: &str) -> (Scratch, Store, Ledger) {
	let dir = Scratch::create(label);
	let store = Store::open(&dir).unwrap();
	let ledger = Ledger::start(&store, Cursor::start()).unwrap();
	(dir, store, ledger)
}

#[test]
fn a_turn_walks_from_running_through_each_line_to_done() {
	let (_dir, store, mut ledger) = fresh("bot-ledger");
	let id = ledger.begin(&store, asked(&[5, 6])).unwrap();
	ledger.start_run(&store, id, 0).unwrap();
	assert!(matches!(
		ledger.phase(id),
		Some(Phase::Running {
			progress: Progress::InFlight,
			..
		})
	));
	ledger.retry(&store, id, "crashed".into()).unwrap();
	assert!(matches!(
		ledger.phase(id),
		Some(Phase::Running {
			spent: 1,
			progress: Progress::Ready,
			..
		})
	));
	ledger
		.answer(&store, id, Content::Answer, vec![part("a", "one"), part("b", "two")])
		.unwrap();
	let sent_at = |base| Attempt::Sent {
		base: Base(base),
		after: event(4),
		looks: 0,
	};
	ledger.attempt(&store, id, sent_at(3)).unwrap();
	assert!(
		ledger.attempt(&store, id, sent_at(4)).is_err(),
		"an operation keeps the base it was first sent at"
	);
	ledger
		.attempt(&store, id, Attempt::Committed { base: Base(3) })
		.unwrap();
	ledger.part_sent(&store, id).unwrap();
	let Some(Phase::Sending { sent, attempt, .. }) = ledger.phase(id) else {
		panic!("the turn is not sending");
	};
	assert_eq!((*sent, attempt), (1, &Attempt::Unsent));
	assert!(
		ledger.reissue(&store, id, "c".into()).is_err(),
		"a line got a new operation before it was sent"
	);
	ledger.attempt(&store, id, sent_at(5)).unwrap();
	ledger.reissue(&store, id, "c".into()).unwrap();
	ledger.part_sent(&store, id).unwrap();
	assert!(
		ledger.part_sent(&store, id).is_err(),
		"a reply sends no line past its last"
	);
	ledger.done(&store, id).unwrap();
	assert!(ledger.open().is_empty());
	assert!(ledger.covers(&event(5)) && ledger.covers(&event(6)) && !ledger.covers(&event(7)));
}

#[test]
fn a_line_settled_without_being_kept_is_never_sent_again() {
	let (_dir, store, mut ledger) = fresh("bot-ledger-releasing");
	let id = ledger.begin(&store, asked(&[1])).unwrap();
	ledger
		.answer(&store, id, Content::Answer, vec![part("a", "1"), part("b", "2")])
		.unwrap();
	let sent = Attempt::Sent {
		base: Base(2),
		after: event(1),
		looks: 0,
	};
	ledger.attempt(&store, id, sent.clone()).unwrap();
	ledger
		.attempt(&store, id, Attempt::Releasing { base: Base(2) })
		.unwrap();
	for back in [sent, Attempt::Committed { base: Base(2) }, Attempt::Unsent] {
		assert!(ledger.attempt(&store, id, back.clone()).is_err(), "{back:?}");
	}
	assert!(ledger.reissue(&store, id, "x".into()).is_err());
	assert!(ledger.fail_rest(&store, id, part("f", "failed")).is_err());
	let reloaded = Ledger::load(&store).unwrap().unwrap();
	assert_eq!(
		reloaded.phase(id).cloned(),
		ledger.phase(id).cloned(),
		"the owed release did not survive a restart"
	);
	ledger.part_sent(&store, id).unwrap();
	let handed = Attempt::Handed {
		base: Base(3),
		after: event(1),
	};
	ledger
		.attempt(
			&store,
			id,
			Attempt::Sent {
				base: Base(3),
				after: event(1),
				looks: 0,
			},
		)
		.unwrap();
	ledger.attempt(&store, id, handed).unwrap();
	assert!(
		ledger
			.attempt(&store, id, Attempt::Committed { base: Base(3) })
			.is_err()
	);
	assert!(ledger.reissue(&store, id, "y".into()).is_err());
}

#[test]
fn a_refused_line_is_replaced_by_one_failure_line_after_the_sent_ones() {
	let (_dir, store, mut ledger) = fresh("bot-ledger-refused");
	let id = ledger.begin(&store, asked(&[1])).unwrap();
	ledger
		.answer(
			&store,
			id,
			Content::Answer,
			vec![part("a", "1"), part("b", "2"), part("c", "3")],
		)
		.unwrap();
	ledger.part_sent(&store, id).unwrap();
	ledger.fail_rest(&store, id, part("f", "failed")).unwrap();
	let Some(Phase::Sending {
		parts, content, sent, ..
	}) = ledger.phase(id)
	else {
		panic!("the turn is not sending");
	};
	assert_eq!(*content, Content::Failure);
	assert_eq!(*sent, 1);
	assert_eq!(
		parts.iter().map(|p| p.operation.as_str()).collect::<Vec<_>>(),
		["a", "f"]
	);
}

#[test]
fn a_reload_keeps_every_phase_the_cursor_and_the_turn_numbers() {
	let (_dir, store, mut ledger) = fresh("bot-ledger-reload");
	let running = ledger.begin(&store, asked(&[3])).unwrap();
	let sending = ledger.begin(&store, asked(&[8])).unwrap();
	ledger.start_run(&store, running, 1).unwrap();
	ledger
		.answer(&store, sending, Content::Answer, vec![part("op", "text")])
		.unwrap();
	ledger.advance(&store, &event(2), Seq(3)).unwrap();
	let again = Ledger::load(&store).unwrap().unwrap();
	assert_eq!((again.cursor(), again.cursor_seq()), (&event(2), Seq(3)));
	assert_eq!(again.phase(running), ledger.phase(running));
	assert_eq!(again.phase(sending), ledger.phase(sending));
	let raw = std::fs::read_to_string(store.root().join("turns.json")).unwrap();
	assert!(raw.contains(r#""phase":"sending""#) && !raw.contains('\n'), "{raw}");
	let mut again = again;
	assert!(
		again.begin(&store, asked(&[9])).unwrap() > sending,
		"a reload reused a turn number"
	);
}

#[test]
fn a_damaged_ledger_is_refused_by_name() {
	let (_dir, store, _ledger) = fresh("bot-ledger-damaged");
	std::fs::write(store.root().join("turns.json"), "{").unwrap();
	assert!(matches!(Ledger::load(&store), Err(Error::Unreadable { .. })));
	std::fs::write(
		store.root().join("turns.json"),
		r#"{"cursor":"","cursor_seq":0,"next_turn":1,"turns":[{"id":4,"phase":"done","covered":{"events":[],"last":0}}]}"#,
	)
	.unwrap();
	assert!(matches!(Ledger::load(&store), Err(Error::Unreadable { .. })));
	std::fs::remove_file(store.root().join("turns.json")).unwrap();
	assert!(Ledger::load(&store).unwrap().is_none());
}

#[test]
fn a_write_that_never_landed_leaves_memory_as_the_file_holds_it() {
	use std::os::unix::fs::PermissionsExt;
	let (_dir, store, mut ledger) = fresh("bot-ledger-unchanged");
	// A directory nobody may write refuses the staged copy before any rename.
	let root = store.root().to_owned();
	std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o500)).unwrap();
	let refused = ledger.begin(&store, asked(&[1]));
	std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
	assert!(matches!(refused, Err(Error::Storage(_))), "{refused:?}");
	assert!(ledger.open().is_empty() && !ledger.covers(&event(1)));
	assert_eq!(ledger.begin(&store, asked(&[1])).unwrap(), TurnId(0));
}

#[test]
fn a_write_that_may_have_landed_is_written_again_before_anything_else() {
	let (_dir, store, mut ledger) = fresh("bot-ledger-unsettled");
	let file = store.root().join("turns.json");
	// A directory where the file goes makes the rename itself fail, after
	// which the file may hold either document.
	std::fs::remove_file(&file).unwrap();
	std::fs::create_dir_all(file.join("block")).unwrap();
	assert!(matches!(ledger.begin(&store, asked(&[1])), Err(Error::Unsettled(_))));
	assert!(
		ledger.covers(&event(1)),
		"memory holds the document that may be on disk"
	);
	assert!(ledger.durable(&store).is_err(), "the file still cannot be replaced");
	std::fs::remove_dir_all(&file).unwrap();
	assert_eq!(ledger.begin(&store, asked(&[2])).unwrap(), TurnId(1));
	let read = Ledger::load(&store).unwrap().unwrap();
	assert!(
		read.covers(&event(1)) && read.covers(&event(2)),
		"the next change wrote the unsettled one again first"
	);
	assert_eq!(read.open(), [TurnId(0), TurnId(1)]);
}

#[test]
fn a_finished_turn_fences_its_replay_until_the_cursor_number_passes_it() {
	let (_dir, store, mut ledger) = fresh("bot-ledger-fence");
	let early = ledger.begin(&store, asked(&[2])).unwrap();
	let late = ledger.begin(&store, asked(&[9])).unwrap();
	assert_eq!(ledger.finished(), 0);
	ledger.done(&store, early).unwrap();
	assert_eq!(ledger.finished(), 1);
	ledger.done(&store, late).unwrap();
	assert!(ledger.advance(&store, &event(5), Seq(5)).unwrap());
	assert_eq!(ledger.finished(), 2, "a dropped row is still a finished turn");
	assert!(
		ledger.phase(early).is_none(),
		"a finished turn behind the cursor is dropped"
	);
	assert!(
		ledger.covers(&event(9)),
		"a finished turn ahead of it still fences its replay"
	);
	assert!(
		!ledger.advance(&store, &event(4), Seq(5)).unwrap(),
		"the cursor never moves back"
	);
	assert_eq!(ledger.cursor(), &event(5));
	assert!(ledger.advance(&store, &event(9), Seq(10)).unwrap());
	assert!(ledger.phase(late).is_none());
}

#[test]
fn an_open_turn_is_never_dropped_by_the_cursor() {
	let (_dir, store, mut ledger) = fresh("bot-ledger-open");
	let id = ledger.begin(&store, asked(&[1])).unwrap();
	ledger.advance(&store, &event(50), Seq(50)).unwrap();
	assert!(ledger.phase(id).is_some());
}

#[test]
fn turns_wait_once_the_open_or_row_bounds_are_reached_and_a_cursor_move_frees_rows() {
	let (_dir, store, mut ledger) = fresh("bot-ledger-bounds");
	let too_many: Vec<u64> = (0..=MAX_TRIGGERS as u64).collect();
	assert!(ledger.begin(&store, asked(&too_many)).is_err());
	for open in 0..MAX_OPEN as u64 {
		assert!(ledger.has_room());
		ledger.begin(&store, asked(&[open])).unwrap();
	}
	assert!(!ledger.has_room(), "a turn past the open bound fits");
	assert!(ledger.begin(&store, asked(&[99])).is_err());
	for id in ledger.open() {
		ledger.done(&store, id).unwrap();
	}
	for seq in 100..100 + MAX_OPEN as u64 {
		ledger.begin(&store, asked(&[seq])).unwrap();
	}
	let first_new = ledger.open()[0];
	ledger.done(&store, first_new).unwrap();
	assert!(
		!ledger.has_room(),
		"finished rows the cursor has not passed still count"
	);
	ledger.advance(&store, &event(99), Seq(99)).unwrap();
	assert!(ledger.has_room(), "the cursor move did not drop the rows it passed");
}

#[test]
fn a_turn_takes_later_triggers_only_until_its_harness_starts() {
	let (_dir, store, mut ledger) = fresh("bot-ledger-extend");
	let id = ledger.begin(&store, asked(&[1])).unwrap();
	assert_eq!(ledger.room_in(id), MAX_TRIGGERS - 1);
	ledger.extend(&store, id, asked(&[2, 3]).triggers).unwrap();
	assert!(ledger.covers(&event(3)));
	let past: Vec<u64> = (10..10 + MAX_TRIGGERS as u64).collect();
	assert!(ledger.extend(&store, id, asked(&past).triggers).is_err());
	ledger.start_run(&store, id, 0).unwrap();
	assert_eq!(ledger.room_in(id), 0);
	assert!(ledger.extend(&store, id, asked(&[4]).triggers).is_err());
	assert!(!ledger.covers(&event(4)));
}

/// Every text at its bound, made of control characters, which JSON writes at
/// six bytes each.
fn widest(bytes: usize) -> String {
	"\u{1}".repeat(bytes)
}

fn widest_trigger(seq: u64) -> Trigger {
	let file = Attachment {
		token: widest(MAX_NAME_BYTES),
		index: usize::MAX,
		name: widest(MAX_LABEL_BYTES),
		mime: widest(MAX_LABEL_BYTES),
		size: usize::MAX,
		width: u32::MAX,
		height: u32::MAX,
	};
	Trigger {
		seq: Seq(u64::MAX - seq),
		event: Cursor::new(widest(Cursor::MAX_BYTES)).unwrap(),
		line: widest(MAX_NAME_BYTES),
		from: Some(widest(rooms_application::room::inbox::MAX_NICK)),
		text: widest(MAX_LINE_BYTES),
		files: vec![file; MAX_MESSAGE_FILES],
	}
}

#[test]
fn the_ledger_at_every_bound_stays_under_the_size_it_reads_back() {
	let mut ledger = Ledger {
		cursor: Cursor::new(widest(Cursor::MAX_BYTES)).unwrap(),
		cursor_seq: Seq(u64::MAX),
		next_turn: TurnId(u64::MAX),
		rows: BTreeMap::new(),
		unsettled: false,
	};
	for id in 0..MAX_OPEN as u64 {
		let triggers = (0..MAX_TRIGGERS as u64).map(widest_trigger).collect();
		ledger.rows.insert(
			TurnId(u64::MAX - id),
			Phase::Running {
				asked: Asked {
					conversation: ConversationId::new(widest(
						rooms_application::content::session::workspace::MAX_ID_UNITS,
					)),
					kind: Kind::Direct,
					triggers,
				},
				spent: u32::MAX,
				note: Some(widest(MAX_NOTE_BYTES)),
				progress: Progress::CutOff,
			},
		);
	}
	for id in 0..(MAX_ROWS - MAX_OPEN) as u64 {
		ledger.rows.insert(
			TurnId(id),
			Phase::Done {
				covered: Covered {
					events: vec![Cursor::new(widest(Cursor::MAX_BYTES)).unwrap(); MAX_TRIGGERS],
					last: Seq(u64::MAX),
				},
			},
		);
	}
	let running = ledger.encode().unwrap().len();
	assert!(running <= MAX_LEDGER_BYTES, "{running} bytes");
	// A sending row holds its lines in place of its triggers. Check that shape too.
	let parts = (0..crate::bot::reply::MAX_PARTS)
		.map(|_| part(&"f".repeat(32), &widest(MAX_LINE_BYTES)))
		.collect::<Vec<_>>();
	for phase in ledger.rows.values_mut().filter(|phase| phase.is_open()) {
		*phase = Phase::Sending {
			conversation: ConversationId::new(widest(rooms_application::content::session::workspace::MAX_ID_UNITS)),
			covered: Covered {
				events: vec![Cursor::new(widest(Cursor::MAX_BYTES)).unwrap(); MAX_TRIGGERS],
				last: Seq(u64::MAX),
			},
			content: Content::Answer,
			parts: parts.clone(),
			sent: usize::MAX,
			attempt: Attempt::Sent {
				base: Base(u64::MAX),
				after: Cursor::new(widest(Cursor::MAX_BYTES)).unwrap(),
				looks: u32::MAX,
			},
		};
	}
	let sending = ledger.encode().unwrap().len();
	assert!(sending <= MAX_LEDGER_BYTES, "{sending} bytes");
}

#[test]
fn a_ledger_past_its_bound_is_a_typed_refusal_before_any_write() {
	let (_dir, store, mut ledger) = fresh("bot-ledger-too-large");
	let mut huge = asked(&[1]);
	huge.triggers[0].text = "x".repeat(MAX_LEDGER_BYTES);
	let before = std::fs::read(store.root().join("turns.json")).unwrap();
	assert!(matches!(ledger.begin(&store, huge), Err(Error::TooLarge { .. })));
	assert_eq!(std::fs::read(store.root().join("turns.json")).unwrap(), before);
	assert!(ledger.open().is_empty());
}
