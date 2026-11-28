//! The replaced lines a start settles, against the stand-in session: a
//! committed line is kept, an unknown one is released, a release answered
//! running is asked again, and one the session refuses leaves the receipt and
//! drops the record. The ledger counts a left receipt only while it holds a
//! place.
#![cfg(feature = "test-support")]
use super::*;
use crate::bot::{
	classify::{Seq, Trigger},
	engine::{Publishing, env::Core},
	ledger::{Asked, Content, Ledger, Part},
	rooms::{Base, ConversationId, Cursor, Kind, files::Files},
	status::Facts,
	store::Store,
	words::RECEIPT_LEFT,
};
use rooms_application::content::session::effects::RUNNING_BOUND_MS;
use rooms_testing::scratch::Scratch;

const TEXT: &str = "finished by another access";

struct Rig {
	_scratch: Scratch,
	session: std::path::PathBuf,
	store: Store,
	rooms: Files,
	line: Replaced,
}

/// A bot whose ledger records `operation` as replaced, and a session that
/// holds its receipt as `fault` leaves it: `committed` or `unknown`.
async fn rig(label: &str, fault: Option<&str>) -> (Rig, Ledger) {
	let scratch = Scratch::create(label);
	let (bot, session) = (scratch.join("bot"), scratch.join("session"));
	std::fs::create_dir_all(&session).unwrap();
	let (store, rooms) = (Store::open(&bot).unwrap(), Files::open(&session));
	let conversation = ConversationId::new("c1");
	let line = Replaced {
		operation: "op0".into(),
		base: Base(0),
		conversation: conversation.clone(),
		text: TEXT.into(),
	};
	if let Some(fault) = fault {
		std::fs::write(session.join("send-faults"), format!("{fault}\n")).unwrap();
	}
	let sent = Outgoing {
		conversation: &conversation,
		text: TEXT,
		operation: "op0",
	};
	rooms.send(&sent, Base(0)).await.unwrap();
	let mut ledger = Ledger::start(&store, Cursor::start()).unwrap();
	let trigger = Trigger {
		opening_until: None,
		scope: None,
		seq: Seq(1),
		event: Cursor::new("e1".to_owned()).unwrap(),
		line: "l1".into(),
		from: None,
		text: "asked".into(),
		files: Vec::new(),
	};
	let id = ledger
		.begin(
			&store,
			Asked {
				conversation,
				kind: Kind::Direct,
				triggers: vec![trigger],
			},
		)
		.unwrap();
	let parts = vec![Part {
		operation: "op0".into(),
		text: TEXT.into(),
	}];
	ledger.answer(&store, id, Content::Answer, parts).unwrap();
	assert_eq!(ledger.part_replaced(&store, id, line.clone()).unwrap(), None);
	let rig = Rig {
		_scratch: scratch,
		session,
		store,
		rooms,
		line,
	};
	(rig, ledger)
}

fn held(session: &std::path::Path) -> bool {
	std::fs::read_to_string(session.join("receipts.json")).is_ok_and(|text| text.contains("op0"))
}

/// Whether the session holds the receipt as released, as it does until newer
/// receipts push it out.
fn released(session: &std::path::Path) -> bool {
	std::fs::read_to_string(session.join("receipts.json")).is_ok_and(|text| text.contains("\"released\":true"))
}

fn kept(session: &std::path::Path) -> bool {
	std::fs::read_to_string(session.join("receipts.json")).is_ok_and(|text| text.contains("\"kept\":true"))
}

#[tokio::test]
async fn a_committed_line_is_kept_and_its_record_dropped() {
	let (rig, ledger) = rig("bot-replaced-keep", None).await;
	let env = Core::new(
		&rig.rooms,
		&rig.store,
		ledger,
		Facts::default(),
		BTreeSet::new(),
		Publishing::Nowhere,
	);
	let mut wait = Backoff::standard();
	assert!(
		step(&env, &rig.line, &mut wait, &mut Running::default())
			.await
			.is_none()
	);
	assert!(env.ledger.borrow().replaced().is_empty());
	assert!(kept(&rig.session), "the session holds the receipt as kept");
	assert!(
		std::fs::read_to_string(rig.store.root().join("bot.log"))
			.unwrap()
			.contains(LINE_KEPT)
	);
}

#[tokio::test]
async fn an_unknown_line_is_released_and_its_record_dropped() {
	let (rig, ledger) = rig("bot-replaced-release", Some("unknown")).await;
	assert!(held(&rig.session));
	let env = Core::new(
		&rig.rooms,
		&rig.store,
		ledger,
		Facts::default(),
		BTreeSet::new(),
		Publishing::Nowhere,
	);
	let mut wait = Backoff::standard();
	assert!(
		step(&env, &rig.line, &mut wait, &mut Running::default())
			.await
			.is_none()
	);
	assert!(released(&rig.session), "the receipt was given back");
	assert!(env.ledger.borrow().replaced().is_empty());
	assert!(
		std::fs::read_to_string(rig.store.root().join("bot.log"))
			.unwrap()
			.contains(LINE_RELEASED)
	);
}

/// A release answered running clears once the session's executor settles or
/// pauses, so it is asked again while the session's running bound has not
/// passed since it first answered running.
#[tokio::test(start_paused = true)]
async fn a_release_answered_running_is_asked_again_until_it_clears() {
	let (rig, ledger) = rig("bot-replaced-running", Some("unknown")).await;
	let env = Core::new(
		&rig.rooms,
		&rig.store,
		ledger,
		Facts::default(),
		BTreeSet::new(),
		Publishing::Nowhere,
	);
	let (mut wait, mut running) = (Backoff::standard(), Running::default());
	for round in 1..=6 {
		// The look passes and the release answers running, each round a
		// further part of the bound later.
		std::fs::write(rig.session.join("send-faults"), "ok\nexecutor-running\n").unwrap();
		assert!(
			step(&env, &rig.line, &mut wait, &mut running).await.is_some(),
			"round {round}: the release was given up on"
		);
		tokio::time::advance(Duration::from_millis(RUNNING_BOUND_MS / 8)).await;
		assert_eq!(
			env.ledger.borrow().replaced().len(),
			1,
			"round {round}: the record waits"
		);
	}
	assert!(held(&rig.session) && !released(&rig.session));
	assert_eq!(env.ledger.borrow().left(), 0);
	std::fs::remove_file(rig.session.join("send-faults")).unwrap();
	assert!(step(&env, &rig.line, &mut wait, &mut running).await.is_none());
	assert!(released(&rig.session), "the receipt was given back once it cleared");
	assert!(env.ledger.borrow().replaced().is_empty());
	assert!(!log(&rig).contains(RECEIPT_LEFT));
}

/// The session settles or pauses a running executor within its running bound,
/// so a release still answered running past it is a refusal: the record goes
/// and the receipt, which a look finds committed and so holding a place, is
/// counted as left with the session.
#[tokio::test(start_paused = true)]
async fn a_release_running_past_the_sessions_bound_is_left() {
	let (rig, ledger) = rig("bot-replaced-running-bound", None).await;
	let env = Core::new(
		&rig.rooms,
		&rig.store,
		ledger,
		Facts::default(),
		BTreeSet::new(),
		Publishing::Nowhere,
	);
	let (mut wait, mut running) = (Backoff::standard(), Running::default());
	// The look finds it committed, the keep is refused, and the release
	// answers running.
	let faults = "ok\nrefused\nexecutor-running\n";
	std::fs::write(rig.session.join("send-faults"), faults).unwrap();
	assert!(step(&env, &rig.line, &mut wait, &mut running).await.is_some());
	tokio::time::advance(Duration::from_millis(RUNNING_BOUND_MS)).await;
	std::fs::write(rig.session.join("send-faults"), faults).unwrap();
	assert!(step(&env, &rig.line, &mut wait, &mut running).await.is_none());
	assert!(
		held(&rig.session) && !released(&rig.session),
		"the receipt stays with the session"
	);
	assert!(env.ledger.borrow().replaced().is_empty());
	assert_eq!(env.ledger.borrow().left(), 1);
	assert!(log(&rig).contains(RECEIPT_LEFT));
}

/// A release the session refuses for good will not change, so the receipt is
/// left with the session at once and the log says so. The ledger counts it
/// when a look finds it may still hold a place: a committed line nobody kept
/// does, and so does an unknown one, as a paused executor's receipt does
/// until it is released.
#[tokio::test]
async fn a_release_the_session_refuses_for_good_leaves_the_receipt_and_drops_the_record() {
	// The look finds it committed, then the keep and the release are refused.
	for (fault, faults, counted) in [
		(None, "ok\nrefused\nrefused\n", 1),
		(Some("unknown"), "ok\nrefused\n", 1),
	] {
		let (rig, ledger) = rig("bot-replaced-refused", fault).await;
		let env = Core::new(
			&rig.rooms,
			&rig.store,
			ledger,
			Facts::default(),
			BTreeSet::new(),
			Publishing::Nowhere,
		);
		let mut wait = Backoff::standard();
		std::fs::write(rig.session.join("send-faults"), faults).unwrap();
		assert!(
			step(&env, &rig.line, &mut wait, &mut Running::default())
				.await
				.is_none()
		);
		assert!(
			held(&rig.session) && !released(&rig.session),
			"the receipt stays with the session"
		);
		assert!(env.ledger.borrow().replaced().is_empty());
		assert_eq!(env.ledger.borrow().left(), counted, "{fault:?}");
		assert!(log(&rig).contains(RECEIPT_LEFT));
	}
}

/// A look the session refuses is an answer that will not change, so the
/// record is spent and the receipt is left, never asked about forever.
/// Nothing says whether it holds a place, so it is not counted.
#[tokio::test]
async fn a_refused_look_leaves_the_receipt_and_drops_the_record() {
	let (rig, ledger) = rig("bot-replaced-look-refused", Some("unknown")).await;
	let env = Core::new(
		&rig.rooms,
		&rig.store,
		ledger,
		Facts::default(),
		BTreeSet::new(),
		Publishing::Status,
	);
	let mut wait = Backoff::standard();
	std::fs::write(rig.session.join("send-faults"), "refused\n").unwrap();
	assert!(
		step(&env, &rig.line, &mut wait, &mut Running::default())
			.await
			.is_none()
	);
	assert!(held(&rig.session));
	assert!(env.ledger.borrow().replaced().is_empty());
	assert_eq!(env.ledger.borrow().left(), 0);
	assert_eq!(published(&rig)["unreleased_lines"], 0);
	assert!(log(&rig).contains("the session refused a look at operation op0"));
}

/// A record that cannot be dropped is tried again and shows in the status
/// file as a failure to save. A refused look counts nothing.
#[tokio::test]
async fn a_record_that_cannot_be_dropped_is_published_and_counted_once() {
	// The look is refused twice.
	counted_once("bot-replaced-drop-fails", Some("unknown"), "refused\nrefused\n", 0).await;
}

/// The same for a release the session refuses of a committed line nobody
/// kept: its receipt is counted once, though the ledger refused the first
/// write, and logged once.
#[tokio::test]
async fn a_refused_release_whose_record_cannot_be_dropped_is_counted_once() {
	// The look finds it committed, the keep and the release are refused, and
	// the look that decides whether it holds a place finds it committed, twice.
	let faults = "ok\nrefused\nrefused\nok\nok\nrefused\nrefused\nok\n";
	let log = counted_once("bot-replaced-release-drop-fails", None, faults, 1).await;
	assert_eq!(log.matches(RECEIPT_LEFT).count(), 1, "{log}");
}

/// Step a replaced line whose ledger cannot be written at first, under
/// `faults`, check it counts `counted` left receipts, and answer the log.
async fn counted_once(label: &str, fault: Option<&str>, faults: &str, counted: usize) -> String {
	let (rig, ledger) = rig(label, fault).await;
	let env = Core::new(
		&rig.rooms,
		&rig.store,
		ledger,
		Facts::default(),
		BTreeSet::new(),
		Publishing::Status,
	);
	let mut wait = Backoff::standard();
	std::fs::write(rig.session.join("send-faults"), faults).unwrap();
	// A bot directory moved aside refuses the ledger's staged copy before any
	// rename, so the file still holds the record. It refuses the status file
	// too, which is published again once the directory is back.
	let displaced = crate::bot::store::Displaced::new(rig.store.root());
	let stepped = step(&env, &rig.line, &mut wait, &mut Running::default()).await;
	displaced.restore();
	assert!(stepped.is_some());
	assert_eq!(env.ledger.borrow().replaced().len(), 1);
	assert_eq!(env.ledger.borrow().left(), 0);
	env.publish();
	assert_eq!(published(&rig)["last_error"]["during"], "saving", "{}", published(&rig));
	assert!(
		step(&env, &rig.line, &mut wait, &mut Running::default())
			.await
			.is_none()
	);
	assert!(env.ledger.borrow().replaced().is_empty());
	assert_eq!(env.ledger.borrow().left(), counted);
	let status = published(&rig);
	assert_eq!(status["unreleased_lines"], counted);
	assert!(status["last_error"].is_null(), "{status}");
	log(&rig)
}

/// What the status file holds now.
fn published(rig: &Rig) -> serde_json::Value {
	serde_json::from_slice(&std::fs::read(rig.store.root().join("status.json")).unwrap()).unwrap()
}

fn log(rig: &Rig) -> String {
	std::fs::read_to_string(rig.store.root().join("bot.log")).unwrap()
}
