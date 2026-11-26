use super::*;
use crate::bot::{
	classify::{MAX_LABEL_BYTES, MAX_NAME_BYTES},
	rooms::{Attachment, Base, Kind},
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
			runs: Runs {
				progress: Progress::InFlight,
				..
			},
			..
		})
	));
	ledger.retry(&store, id, "crashed".into()).unwrap();
	assert!(matches!(
		ledger.phase(id),
		Some(Phase::Running {
			runs: Runs {
				spent: 1,
				progress: Progress::Ready,
			},
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
	let (_dir, store, mut ledger) = fresh("bot-ledger-unchanged");
	let displaced = crate::bot::store::Displaced::new(store.root());
	let refused = ledger.begin(&store, asked(&[1]));
	displaced.restore();
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
	assert_eq!(
		ledger.begin(&store, asked(&[1])).unwrap(),
		TurnId(0),
		"the caller holds the turn memory holds"
	);
	assert!(
		ledger.covers(&event(1)),
		"memory holds the document that may be on disk"
	);
	assert!(
		matches!(ledger.durable(&store), Err(Error::Unsettled(_))),
		"the file still cannot be replaced"
	);
	assert!(
		matches!(ledger.begin(&store, asked(&[2])), Err(Error::Unsettled(_))),
		"no change is made while the last one is unwritten"
	);
	assert!(!ledger.covers(&event(2)));
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
fn a_run_whose_start_cannot_be_made_durable_spends_nothing() {
	let (_dir, store, mut ledger) = fresh("bot-ledger-start-run");
	let id = ledger.begin(&store, asked(&[1])).unwrap();
	let file = store.root().join("turns.json");
	std::fs::remove_file(&file).unwrap();
	std::fs::create_dir_all(file.join("block")).unwrap();
	assert!(matches!(ledger.start_run(&store, id, 0), Err(Error::Unsettled(_))));
	assert!(
		matches!(
			ledger.phase(id),
			Some(Phase::Running {
				runs: Runs {
					progress: Progress::Ready,
					..
				},
				..
			})
		),
		"a run the harness never began is in memory as started"
	);
	std::fs::remove_dir_all(&file).unwrap();
	ledger.start_run(&store, id, 0).unwrap();
	let read = Ledger::load(&store).unwrap().unwrap();
	assert!(matches!(
		read.phase(id),
		Some(Phase::Running {
			runs: Runs {
				spent: 0,
				progress: Progress::InFlight,
			},
			..
		})
	));
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
	let scratch = rooms_testing::scratch::Scratch::create("bot-ledger-size");
	let store = Store::open(&scratch).unwrap();
	crate::bot::identity::seed(&store).unwrap();
	let key = crate::bot::identity::action_key(store.root()).unwrap();
	let mut ledger = Ledger {
		cursor: Cursor::new(widest(Cursor::MAX_BYTES)).unwrap(),
		cursor_seq: Seq(u64::MAX),
		next_turn: TurnId(u64::MAX),
		rows: BTreeMap::new(),
		replaced: (0..MAX_REPLACED)
			.map(|_| Replaced {
				operation: key.mint().unwrap(),
				base: Base(u64::MAX),
				conversation: ConversationId::new(widest(rooms_application::content::session::workspace::MAX_ID_UNITS)),
				text: widest(MAX_LINE_BYTES),
			})
			.collect(),
		left: (0..MAX_REPLACED).map(|_| key.mint().unwrap()).collect(),
		replaced_actions: (0..MAX_REPLACED).map(|_| key.mint().unwrap()).collect(),
		unlisted: Some(Unlisted::Paused),
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
				runs: Runs {
					spent: u32::MAX,
					progress: Progress::CutOff,
				},
				note: Some(widest(MAX_NOTE_BYTES)),
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
		.map(|_| part(&key.mint().unwrap(), &widest(MAX_LINE_BYTES)))
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

/// A turn with `count` lines, each sent and committed at base 1.
fn sending(store: &Store, ledger: &mut Ledger, count: usize) -> TurnId {
	let id = ledger.begin(store, asked(&[1])).unwrap();
	let parts = (0..count).map(|line| part(&format!("op{line}"), "text")).collect();
	ledger.answer(store, id, Content::Answer, parts).unwrap();
	id
}

fn replaced(operation: &str) -> Replaced {
	Replaced {
		operation: operation.into(),
		base: Base(1),
		conversation: ConversationId::new("c1"),
		text: "text".into(),
	}
}

#[test]
fn a_line_finished_by_its_echo_is_settled_and_recorded_in_one_write_and_dropped_when_asked() {
	let (_dir, store, mut ledger) = fresh("bot-ledger-replaced");
	let id = sending(&store, &mut ledger, 2);
	assert_eq!(ledger.part_replaced(&store, id, replaced("op0")).unwrap(), None);
	let Some(Phase::Sending { sent, .. }) = ledger.phase(id) else {
		panic!("the turn is not sending");
	};
	assert_eq!((*sent, ledger.replaced()), (1, &[replaced("op0")][..]));
	let loaded = Ledger::load(&store).unwrap().unwrap();
	assert_eq!(loaded.replaced(), ledger.replaced(), "the record is in the file");
	assert!(loaded.sent().is_empty(), "a settled line is no line to ask about");
	ledger
		.drop_replaced(&store, &BTreeSet::from(["other".to_owned()]))
		.unwrap();
	assert_eq!(ledger.replaced().len(), 1, "a record nobody named stays");
	ledger
		.drop_replaced(&store, &BTreeSet::from(["op0".to_owned()]))
		.unwrap();
	assert!(ledger.replaced().is_empty());
	assert!(Ledger::load(&store).unwrap().unwrap().replaced().is_empty());
}

#[test]
fn a_record_past_the_bound_drops_the_oldest_and_returns_it() {
	let (_dir, store, mut ledger) = fresh("bot-ledger-replaced-bound");
	let id = sending(&store, &mut ledger, MAX_REPLACED + 1);
	for line in 0..MAX_REPLACED {
		assert_eq!(
			ledger
				.part_replaced(&store, id, replaced(&format!("op{line}")))
				.unwrap(),
			None
		);
	}
	let dropped = ledger
		.part_replaced(&store, id, replaced(&format!("op{MAX_REPLACED}")))
		.unwrap();
	assert_eq!(dropped, Some(replaced("op0")));
	assert_eq!(ledger.replaced().len(), MAX_REPLACED);
	assert_eq!(ledger.replaced()[0], replaced("op1"));
}

#[test]
fn a_ledger_holding_more_records_than_the_session_has_places_or_one_twice_is_unreadable() {
	let (_dir, store, mut ledger) = fresh("bot-ledger-replaced-unreadable");
	ledger.replaced = (0..=MAX_REPLACED).map(|line| replaced(&format!("op{line}"))).collect();
	ledger.persist(&store).unwrap();
	assert!(matches!(Ledger::load(&store), Err(Error::Unreadable { .. })));
	ledger.replaced = vec![replaced("op0"), replaced("op0")];
	ledger.persist(&store).unwrap();
	assert!(matches!(Ledger::load(&store), Err(Error::Unreadable { .. })));
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

/// The process test of a crowd of conversations (`tests/bot_process/turns.rs`)
/// cannot import the bound, so it must name the rows the ledger holds.
#[test]
fn the_crowd_process_test_names_the_rows_the_ledger_holds() {
	let test = include_str!("../../../../tests/bot_process/turns.rs");
	assert!(
		test.contains(&format!("const ROWS: u64 = {MAX_ROWS};")),
		"turns.rs names another row count than MAX_ROWS ({MAX_ROWS})"
	);
}
