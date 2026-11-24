//! The old access's last look leaves the opens of the turns still open in the
//! ledger, which the new link settles once it serves. Its last list of the
//! agent's actions is part of the replacement: a list that fails refuses it,
//! unless the old access is revoked, paused, or no longer held by the session.
use super::*;
use crate::bot::{
	classify::{Seq, Trigger},
	ledger::{Asked, Unlisted},
	rooms::{Base, ConversationId, Cursor, Kind, files::Files},
};
use rooms_services::session::attached::Introduction;
use rooms_testing::scratch::Scratch;

#[tokio::test]
async fn a_last_look_leaves_the_open_of_a_turn_still_open() {
	assert!(
		last_look_keeps_the_note("bot-replace-open-turn", true).await,
		"the last look settled the open of a turn still open"
	);
}

#[tokio::test]
async fn a_last_look_settles_the_open_of_a_turn_no_longer_open() {
	assert!(
		!last_look_keeps_the_note("bot-replace-closed-turn", false).await,
		"the last look left the open of a turn the ledger no longer holds"
	);
}

/// Whether the old access's last look leaves the note of an open the session
/// answers opened, when the note names the ledger's open turn, if
/// `turn_open`, or a turn the ledger does not hold.
async fn last_look_keeps_the_note(label: &str, turn_open: bool) -> bool {
	let scratch = Scratch::create(label);
	let session = scratch.join("session");
	std::fs::create_dir_all(&session).unwrap();
	let rooms = Files::open(&session);
	let store = Store::open(&scratch.join("bot")).unwrap();
	let mut ledger = Ledger::start(&store, Cursor::start()).unwrap();
	let conversation = ConversationId::new("c1");
	let turn = ledger
		.begin(
			&store,
			Asked {
				conversation: conversation.clone(),
				kind: Kind::Direct,
				triggers: vec![Trigger {
					seq: Seq(1),
					event: Cursor::new("e1".to_owned()).unwrap(),
					line: "l1".into(),
					from: None,
					text: "open a direct conversation".into(),
					files: Vec::new(),
				}],
			},
		)
		.unwrap();
	let operation = format!("{:032x}", 1);
	let open = opens::Open {
		base: Base(3),
		introduction: Introduction {
			directory: "d".into(),
			peer: "ann".into(),
			registration: "r".into(),
		},
		conversation,
		turn: if turn_open { turn } else { TurnId(turn.0 + 1) },
	};
	opens::note(store.root(), &operation, &open).unwrap();
	std::fs::write(session.join("open-answers"), "opened\n").unwrap();
	let (_stop, shutdown) = watch::channel(false);
	settle_old_access(
		&rooms,
		&store,
		ledger,
		&shutdown,
		Instant::now() + Duration::from_secs(10),
	)
	.await
	.unwrap();
	opens::noted(store.root(), &operation).unwrap().is_some()
}

/// The old access's settling with a fresh ledger, against a stand-in whose
/// `held-actions` lists one action the session still runs.
async fn settled_with_one_running_action(label: &str, list: &str) -> (Scratch, Store, Result<OldSettled, Error>) {
	settled_within(label, list, Duration::from_secs(10), |_, _| {}).await
}

/// [`settled_with_one_running_action`] with `limit` for the old access's
/// lines and opens, and `prepare` to add to the session and the bot
/// directory first.
async fn settled_within(
	label: &str,
	list: &str,
	limit: Duration,
	prepare: impl Fn(&std::path::Path, &Store),
) -> (Scratch, Store, Result<OldSettled, Error>) {
	let scratch = Scratch::create(label);
	let session = scratch.join("session");
	std::fs::create_dir_all(&session).unwrap();
	let rooms = Files::open(&session);
	let store = Store::open(&scratch.join("bot")).unwrap();
	let ledger = Ledger::start(&store, Cursor::start()).unwrap();
	prepare(&session, &store);
	std::fs::write(session.join("held-actions"), format!("{:032x}\n", 7)).unwrap();
	std::fs::write(session.join("held-answers"), format!("{list}\n")).unwrap();
	std::fs::write(session.join("action-answers"), "pending\n").unwrap();
	let (_stop, shutdown) = watch::channel(false);
	let settled = settle_old_access(&rooms, &store, ledger, &shutdown, Instant::now() + limit).await;
	(scratch, store, settled)
}

fn replaced_actions(store: &Store) -> Vec<String> {
	Ledger::load(store).unwrap().unwrap().replaced_actions().to_vec()
}

/// Only the old access can list the actions it holds, so a list that fails
/// for a reason that may clear refuses the replacement, retryably, and
/// records nothing. A list that answers records the running action.
#[tokio::test]
async fn a_last_list_that_fails_refuses_the_replacement_and_records_nothing() {
	let (_scratch, store, settled) = settled_with_one_running_action("bot-replace-unlisted", "unreachable").await;
	match settled {
		Err(error @ Error::Unlisted(_)) => assert!(error.is_transient(), "{error}"),
		Err(error) => panic!("another failure: {error}"),
		Ok(_) => panic!("a replacement went on without the old access's list"),
	}
	assert_eq!(replaced_actions(&store), Vec::<String>::new());
	let (_scratch, store, settled) = settled_with_one_running_action("bot-replace-listed", "ok").await;
	settled.unwrap();
	assert_eq!(replaced_actions(&store), vec![format!("{:032x}", 7)]);
}

/// A list the session refuses for good refuses the replacement too, and
/// waiting does not clear it.
#[tokio::test]
async fn a_last_list_the_session_refuses_refuses_the_replacement_for_good() {
	let (_scratch, store, settled) = settled_with_one_running_action("bot-replace-list-refused", "refused").await;
	match settled {
		Err(error @ Error::Unlisted(_)) => assert!(!error.is_transient(), "{error}"),
		Err(error) => panic!("another failure: {error}"),
		Ok(_) => panic!("a replacement went on without the old access's list"),
	}
	assert_eq!(replaced_actions(&store), Vec::<String>::new());
}

/// The session's answer that the old access is revoked promises its receipts
/// back, and its answer that it no longer holds the access promises nothing
/// (`Refused` of `attached/error.rs`). A replacement holds opens and actions
/// to the same answer: a revoked access's open settles and its actions are
/// not recorded, while a denied access's open stays unsettled and its actions
/// are recorded as unlisted, which `status.replaced_unlisted` says.
#[tokio::test]
async fn an_old_access_is_held_to_one_answer_for_its_opens_and_its_actions() {
	for (answer, note_goes, unlisted) in [("revoked", true, None), ("denied", false, Some(Unlisted::Denied))] {
		let label = format!("bot-replace-list-{answer}");
		let operation = format!("{:032x}", 8);
		let prepare = |session: &std::path::Path, store: &Store| {
			let open = opens::Open {
				base: Base(3),
				introduction: Introduction {
					directory: "d".into(),
					peer: "ann".into(),
					registration: "r".into(),
				},
				conversation: ConversationId::new("c1"),
				turn: TurnId(1),
			};
			opens::note(store.root(), &format!("{:032x}", 8), &open).unwrap();
			std::fs::write(session.join("open-answers"), format!("{answer}\n")).unwrap();
		};
		let (_scratch, store, settled) = settled_within(&label, answer, Duration::from_secs(10), prepare).await;
		let settled = settled.unwrap();
		assert_eq!(
			opens::noted(store.root(), &operation).unwrap().is_none(),
			note_goes,
			"{answer}"
		);
		assert_eq!(settled.unlisted, unlisted, "{answer}");
		assert_eq!(replaced_actions(&store), Vec::<String>::new(), "{answer}");
		let log = store_log(&store);
		assert_eq!(
			log.contains("revoking it gave every one back"),
			unlisted.is_none(),
			"{answer}: {log}"
		);
	}
}

fn store_log(store: &Store) -> String {
	std::fs::read_to_string(store.root().join("bot.log")).unwrap_or_default()
}

/// The limit bounds the old access's lines and opens. Its list is the only
/// record of its actions, so it runs once the limit has run out too: here
/// the ask about an open's note fails, and the limit ends its wait to ask
/// again.
#[tokio::test]
async fn a_last_list_runs_after_the_limit_ran_out() {
	let unanswered = |session: &std::path::Path, store: &Store| {
		let open = opens::Open {
			base: Base(3),
			introduction: Introduction {
				directory: "d".into(),
				peer: "ann".into(),
				registration: "r".into(),
			},
			conversation: ConversationId::new("c1"),
			turn: TurnId(1),
		};
		opens::note(store.root(), &format!("{:032x}", 8), &open).unwrap();
		std::fs::write(session.join("holder-answers"), "unreachable\n").unwrap();
	};
	let (_scratch, store, settled) = settled_within("bot-replace-list-late", "ok", Duration::ZERO, unanswered).await;
	settled.unwrap();
	let log = store_log(&store);
	assert!(
		log.contains("ran out of time before the session said which receipts are its own"),
		"{log}"
	);
	assert_eq!(replaced_actions(&store), vec![format!("{:032x}", 7)]);
}

/// A paused old access cannot list, and the bot leaves a pause to its
/// operator, so the replacement goes on and says why nothing was listed. The
/// ledger records that only once the start stores the new link, which this
/// test stands in for, and the next replacement's list takes its place.
#[tokio::test]
async fn a_paused_old_access_lets_the_replacement_go_on_and_records_it_unlisted() {
	let (scratch, store, settled) = settled_with_one_running_action("bot-replace-list-paused", "paused").await;
	let OldSettled {
		ledger: mut settled_ledger,
		unlisted,
		..
	} = settled.unwrap();
	assert_eq!(unlisted, Some(Unlisted::Paused));
	assert_eq!(replaced_actions(&store), Vec::<String>::new());
	assert_eq!(
		Ledger::load(&store).unwrap().unwrap().unlisted(),
		None,
		"nothing is recorded before the new link is stored"
	);
	assert!(
		store_log(&store).contains("the old access is paused"),
		"{}",
		store_log(&store)
	);
	settled_ledger.record_unlisted(&store, unlisted).unwrap();
	assert_eq!(
		Ledger::load(&store).unwrap().unwrap().unlisted(),
		Some(Unlisted::Paused)
	);
	let rooms = Files::open(&scratch.join("session"));
	let (_stop, shutdown) = watch::channel(false);
	let deadline = Instant::now() + Duration::from_secs(10);
	let next = settle_old_access(&rooms, &store, settled_ledger, &shutdown, deadline)
		.await
		.unwrap();
	assert_eq!(next.unlisted, None);
	let mut next = next.ledger;
	next.record_unlisted(&store, None).unwrap();
	let next = Ledger::load(&store).unwrap().unwrap();
	assert_eq!(next.unlisted(), None);
	assert_eq!(next.replaced_actions(), [format!("{:032x}", 7)]);
}
