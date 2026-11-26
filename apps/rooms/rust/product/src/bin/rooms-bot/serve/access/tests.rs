//! The answers an ask collects about replaced lines.
#![cfg(feature = "test-support")]
use super::*;
use crate::bot::{
	classify::{Seq, Trigger},
	ledger::{Asked, Content, Part},
	rooms::{Base, ConversationId, Cursor, Kind, files::Files},
};
use rooms_testing::scratch::Scratch;

/// The old access's courtesy look asks through the old access and settles
/// what it holds, and a replaced line it holds again is not its to keep: the
/// serving link's own ask finds the line and its record is left as it is.
#[tokio::test]
async fn a_replaced_line_the_old_access_holds_is_left_in_the_ledger_by_its_look() {
	let scratch = Scratch::create("bot-access-replaced");
	let (bot, session) = (scratch.join("bot"), scratch.join("session"));
	std::fs::create_dir_all(&session).unwrap();
	let (store, rooms) = (Store::open(&bot).unwrap(), Files::open(&session));
	let mut ledger = Ledger::start(&store, Cursor::start()).unwrap();
	let conversation = ConversationId::new("c1");
	let trigger = Trigger {
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
				conversation: conversation.clone(),
				kind: Kind::Direct,
				triggers: vec![trigger],
			},
		)
		.unwrap();
	let parts = vec![Part {
		operation: "op0".into(),
		text: "text".into(),
	}];
	ledger.answer(&store, id, Content::Answer, parts).unwrap();
	let line = Replaced {
		operation: "op0".into(),
		base: Base(0),
		conversation,
		text: "text".into(),
	};
	ledger.part_replaced(&store, id, line.clone()).unwrap();
	let (_stop, shutdown) = watch::channel(false);
	let mut found = ask(&rooms, &store, &ledger, LinkStage::Replacing, Paused::Leave, &shutdown)
		.await
		.unwrap()
		.unwrap();
	assert!(
		found.take_by_echo().is_empty(),
		"a replaced line is no line to settle by echo"
	);
	found.place(&store, &mut ledger).unwrap();
	assert_eq!(ledger.replaced(), [line], "the record waits for the serving link's ask");
	assert_eq!(found.take_mine().len(), 1, "the access that holds it again keeps it");
}

/// The first start sees that nobody holds an open and drops the note. The
/// request arrives after that start exits. Both the ordinary recovery and
/// the last list through the old access must still find its receipt.
#[tokio::test]
async fn a_late_open_is_recognized_after_a_start_removed_its_note() {
	use crate::bot::{ledger::TurnId, opens::action};

	for replacing in [false, true] {
		let scratch = Scratch::create("bot-late-open-note");
		let session = scratch.join("session");
		std::fs::create_dir_all(&session).unwrap();
		let rooms = Files::open(&session);
		let store = Store::open(&scratch.join("bot")).unwrap();
		crate::bot::identity::seed(&store).unwrap();
		let mut snapshot = Ledger::start(&store, Cursor::start()).unwrap();
		let legacy = format!("{:032x}", 17);
		let new = crate::bot::identity::new_action(store.root()).unwrap();
		for (peer, id) in [("ann", &legacy), ("bob", &new)] {
			let open = opens::Open {
				base: Base(1),
				introduction: rooms_services::session::attached::Introduction {
					directory: "d".into(),
					peer: peer.into(),
					registration: peer.into(),
				},
				conversation: ConversationId::new("c"),
				turn: TurnId(1),
			};
			opens::note(store.root(), id, &open).unwrap();
		}
		std::fs::write(session.join("holder-answers"), "nobody\nnobody\n").unwrap();
		let (_stop, shutdown) = tokio::sync::watch::channel(false);
		let placed = ask(&rooms, &store, &snapshot, LinkStage::Stored, Paused::Leave, &shutdown)
			.await
			.unwrap()
			.unwrap();
		assert!(
			!store.root().join("legacy-action-ids.json").exists(),
			"asking alone migrated notes"
		);
		placed.place(&store, &mut snapshot).unwrap();
		assert!(opens::unplaced(store.root()).unwrap().is_empty());
		drop(store);
		let store = Store::open(&scratch.join("bot")).unwrap();
		let ledger = Ledger::load(&store).unwrap().unwrap();
		std::fs::write(session.join("held-actions"), format!("{legacy}\n{new}\n")).unwrap();
		std::fs::write(session.join("action-answers"), "kept\nkept\n").unwrap();
		if replacing {
			action::last(&rooms, &store, &ledger).await.unwrap();
		} else {
			action::settle(
				&rooms,
				&store,
				&std::cell::RefCell::new(ledger),
				&mut action::Strays::default(),
			)
			.await
			.unwrap();
		}
		assert!(
			std::fs::read_to_string(session.join("held-actions"))
				.unwrap()
				.is_empty()
		);
	}
}
