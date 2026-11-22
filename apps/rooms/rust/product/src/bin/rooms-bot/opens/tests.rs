//! Noted opens settle through the stand-in session: a settled answer removes
//! its note, a pending one is looked at again and never given up, evidence
//! sets a note aside, an unreadable note is set aside, a note of a thinking
//! conversation waits for its turn, a replaced link's last look sets aside
//! what it cannot settle, and a note past the bound is refused.
#![cfg(feature = "test-support")]
use super::*;
use crate::bot::{
	classify::{Seq, Trigger},
	ledger::Asked,
	rooms::{Cursor, Kind, files::Files},
};
use rooms_testing::scratch::Scratch;

fn operation(index: usize) -> String {
	format!("{index:032x}")
}

fn open(conversation: &str) -> Open {
	Open {
		base: Base(3),
		introduction: Introduction {
			directory: "d".into(),
			peer: "ann".into(),
			registration: "r".into(),
		},
		conversation: ConversationId::new(conversation),
	}
}

fn answer(rooms: &Path, answers: &str) {
	std::fs::write(rooms.join("open-answers"), answers).unwrap();
}

/// The live notes and the notes set aside, by operation index.
fn notes(store: &Store) -> (Vec<String>, Vec<String>) {
	let mut names: Vec<_> = std::fs::read_dir(store.root().join(DIRECTORY))
		.unwrap()
		.map(|entry| entry.unwrap().file_name().into_string().unwrap())
		.collect();
	names.sort();
	let short = |name: &str| name.trim_start_matches('0').to_owned();
	let live = names
		.iter()
		.filter_map(|name| name.strip_suffix(NOTE))
		.map(short)
		.collect();
	let aside = names
		.iter()
		.filter_map(|name| name.strip_suffix(SET_ASIDE))
		.map(short)
		.collect();
	(live, aside)
}

fn rig(label: &str) -> (Scratch, std::path::PathBuf, Files, Store) {
	let scratch = Scratch::create(label);
	let (bot, session) = (scratch.join("bot"), scratch.join("session"));
	std::fs::create_dir_all(&session).unwrap();
	let rooms = Files::open(&session);
	let store = Store::open(&bot).unwrap();
	(scratch, session, rooms, store)
}

#[tokio::test]
async fn a_pending_open_is_looked_at_again_and_only_evidence_gives_one_up() {
	let (_scratch, session, rooms, store) = rig("bot-opens");
	let ledger = RefCell::new(Ledger::start(&store, Cursor::start()).unwrap());
	let serving = Look::Serving(&ledger);
	let mut waiting = BTreeSet::new();
	assert_eq!(
		look(&rooms, &store, &serving, &mut waiting).await.unwrap(),
		Looked::default()
	);
	for index in 1..=5 {
		note(store.root(), &operation(index), &open("c")).unwrap();
	}
	std::fs::write(
		store.root().join(DIRECTORY).join(format!("{}{NOTE}", operation(6))),
		"{",
	)
	.unwrap();
	answer(&session, "opened\npending\nunknown\npaused\nrefused\n");
	let looked = look(&rooms, &store, &serving, &mut waiting).await.unwrap();
	assert_eq!(
		looked,
		Looked {
			pending: true,
			set_aside: 3,
			unsettled: 3
		}
	);
	assert_eq!(
		notes(&store),
		(vec!["2".into(), "4".into()], vec!["3".into(), "5".into(), "6".into()])
	);
	for _ in 0..3 {
		answer(&session, "pending\nunreachable\n");
		let looked = look(&rooms, &store, &serving, &mut waiting).await.unwrap();
		assert_eq!((looked.pending, looked.set_aside, looked.unsettled), (true, 0, 3));
	}
	assert_eq!(notes(&store).0, ["2", "4"], "no number of pending looks gives one up");
	// A conversation with a turn thinking holds its note for that turn.
	let thinking = Asked {
		conversation: ConversationId::new("c"),
		kind: Kind::Direct,
		triggers: vec![Trigger {
			seq: Seq(1),
			event: Cursor::new("e1").unwrap(),
			line: "l1".into(),
			from: None,
			text: "hi".into(),
			files: Vec::new(),
		}],
	};
	let id = ledger.borrow_mut().begin(&store, thinking).unwrap();
	ledger.borrow_mut().start_run(&store, id, 0).unwrap();
	answer(&session, "");
	assert!(!look(&rooms, &store, &serving, &mut waiting).await.unwrap().pending);
	let log = std::fs::read_to_string(store.root().join("bot.log")).unwrap();
	assert_eq!(
		log.matches("has not settled").count(),
		2,
		"a pending open is logged once\n{log}"
	);
	assert!(log.contains("could not be read"), "{log}");
	assert_eq!(log.matches("gives up on it").count(), 2, "{log}");
	assert_eq!(listed(store.root()).unwrap().1, 3);
}

#[tokio::test]
async fn a_last_look_settles_what_it_can_and_sets_aside_the_rest() {
	let (_scratch, session, rooms, store) = rig("bot-opens-last");
	for index in 1..=5 {
		note(store.root(), &operation(index), &open("c")).unwrap();
	}
	answer(&session, "revoked\nunapplied\nreleased\nunreachable\npending\n");
	let looked = look(&rooms, &store, &Look::Last, &mut BTreeSet::new()).await.unwrap();
	assert_eq!(
		looked,
		Looked {
			pending: false,
			set_aside: 2,
			unsettled: 2
		}
	);
	assert_eq!(notes(&store), (Vec::new(), vec!["4".into(), "5".into()]));
}

#[test]
fn a_note_past_the_bound_is_refused_and_a_settled_one_goes() {
	let scratch = Scratch::create("bot-opens-bound");
	let sent = open("c");
	for index in 1..=MAX_OPENS {
		note(&scratch, &operation(index), &sent).unwrap();
	}
	assert_eq!(noted(&scratch, &operation(1)).unwrap(), Some(sent.clone()));
	let past = operation(MAX_OPENS + 1);
	let Err(Error::Usage(refused)) = note(&scratch, &past, &sent) else {
		panic!("a note past the bound was kept");
	};
	assert!(refused.contains(&MAX_OPENS.to_string()), "{refused}");
	assert_eq!(noted(&scratch, &past).unwrap(), None, "the refused note is removed");
	forget(&scratch, &operation(1)).unwrap();
	forget(&scratch, &operation(1)).unwrap();
	note(&scratch, &past, &sent).unwrap();
	for refused in ["../escape", "not-hex-but-thirty-two-bytes-long", ""] {
		assert!(note(&scratch, refused, &sent).is_err(), "{refused}");
		assert_eq!(noted(&scratch, refused).unwrap(), None, "{refused}");
	}
}
