//! The claims of the agent's actions are bounded by the session's own count
//! of receipt places. The serving loop settles what the stand-in session
//! lists through it, leaves alone what another owner settles, and asks no
//! more about a receipt the session would not take back.
#![cfg(feature = "test-support")]
use super::*;
use crate::bot::group::Verb;
use crate::bot::{
	classify::{Seq, Trigger},
	ledger::{Asked, Attempt, Content, Part, Replaced},
	rooms::{Base, ConversationId, Cursor, Kind, Standing, files::Files},
};
use rooms_testing::scratch::Scratch;

fn operation(index: usize) -> String {
	let nonce = format!("{index:032x}");
	crate::bot::identity::sign(&[3; 16], &nonce)
}

fn turn(id: u64) -> Action {
	Action::new(TurnId(id), What::Say { to: Place::Here })
}

#[test]
fn an_action_past_the_sessions_receipt_places_is_refused_before_it_is_claimed() {
	let scratch = Scratch::create("bot-actions-bound");
	for index in 0..MAX_EFFECTS {
		note(&scratch, &operation(index), &turn(0)).unwrap();
	}
	let past = operation(MAX_EFFECTS);
	let Err(Error::Usage(refused)) = note(&scratch, &past, &turn(0)) else {
		panic!("a claim past the bound was written");
	};
	assert!(refused.contains("actions are still settling"), "{refused}");
	assert!(claimed(&scratch, &past, TurnId(0)).unwrap().is_none());
	forget(&scratch, &operation(2)).unwrap();
	note(&scratch, &past, &turn(0)).unwrap();
	assert!(claimed(&scratch, &past, TurnId(0)).unwrap().is_some());
	assert!(
		claimed(&scratch, &past, TurnId(1)).unwrap().is_none(),
		"another turn does not claim it"
	);
	// The same operation claimed again takes no second place.
	note(&scratch, &past, &turn(0)).unwrap();
}

/// A verb process that has ended, as a claim names it: the harness killed it
/// at its own tool timeout, or it crashed.
fn ended_verb() -> Verb {
	let mut child = std::process::Command::new("sleep").arg("30").spawn().unwrap();
	let verb = Verb::of(child.id()).expect("a running process names itself");
	child.kill().unwrap();
	child.wait().unwrap();
	verb
}

fn turn_of(id: u64, verb: Option<Verb>) -> Action {
	Action { verb, ..turn(id) }
}

/// A claim whose verb runs belongs to it, one whose verb is gone belongs to
/// nobody, and a claim with an outcome never asks about the process.
#[test]
fn a_claim_belongs_to_its_verb_only_while_that_verb_runs() {
	let scratch = Scratch::create("bot-actions-holder");
	assert_eq!(holder(&turn(1)), Holder::Verb, "this process runs");
	assert_eq!(holder(&turn_of(1, Some(ended_verb()))), Holder::Nobody);
	let ended = Action {
		outcome: Some(Outcome::Nothing),
		..turn_of(1, Some(ended_verb()))
	};
	assert_eq!(holder(&ended), Holder::Nobody);
	assert!(matches!(holder(&turn_of(1, None)), Holder::Unjudged(_)));
	let (live, gone) = (operation(1), operation(2));
	note(&scratch, &live, &turn(4)).unwrap();
	note(&scratch, &gone, &turn_of(4, Some(ended_verb()))).unwrap();
	assert_eq!(cut_set(&scratch), BTreeSet::from([gone]));
}

/// The loop writes the outcome its settling learned into the claim of a turn
/// that still runs, and keeps the claim for the turn's next run. A cut claim
/// the session does not list ended in a way nobody can learn. The turn's end
/// removes its claims.
#[tokio::test]
async fn the_loop_writes_what_it_settled_into_the_claims_of_a_running_turn() {
	let (scratch, rooms, store, ledger) = rig("bot-actions-outcome");
	let root = store.root();
	let asked = Asked {
		conversation: ConversationId::new("c1"),
		kind: Kind::Direct,
		triggers: vec![Trigger {
			seq: Seq(1),
			event: Cursor::new("e1").unwrap(),
			line: "l1".into(),
			from: None,
			text: "line 1".into(),
			files: Vec::new(),
		}],
	};
	let id = ledger.borrow_mut().begin(&store, asked).unwrap();
	let (posted, gone, nothing) = (operation(1), operation(2), operation(3));
	let send = What::Send {
		to: Place::Here,
		files: 2,
	};
	for operation in [&posted, &gone, &nothing] {
		let action = Action {
			verb: Some(ended_verb()),
			..Action::new(id, send.clone())
		};
		note(root, operation, &action).unwrap();
	}
	std::fs::write(scratch.join("session/held-actions"), format!("{posted}\n{nothing}\n")).unwrap();
	std::fs::write(scratch.join("session/action-answers"), "kept-incomplete\nunapplied\n").unwrap();
	settle(&rooms, &store, &ledger, &mut Strays::default()).await.unwrap();
	let outcome = |operation: &str| {
		ACTIONS
			.read::<Action>(root, operation, State::Live)
			.unwrap()
			.unwrap()
			.outcome
	};
	assert_eq!(outcome(&posted), Some(Outcome::Posted(Standing::Partial)));
	assert_eq!(outcome(&nothing), Some(Outcome::Nothing));
	assert_eq!(
		outcome(&gone),
		Some(Outcome::Unknown),
		"an unlisted cut claim is unknown"
	);
	assert_eq!(earlier(root, id).unwrap().len(), 3, "the running turn keeps its claims");
	assert_eq!(held_except(root, "").unwrap(), 0, "an ended action holds no place");
	let part = Part {
		operation: operation(9),
		text: "done".into(),
	};
	ledger
		.borrow_mut()
		.answer(&store, id, Content::Answer, vec![part])
		.unwrap();
	settle(&rooms, &store, &ledger, &mut Strays::default()).await.unwrap();
	assert!(
		earlier(root, id).unwrap().is_empty(),
		"the turn's end removed its claims"
	);
}

/// A running turn's claim whose verb runs is settled by nobody else, even
/// when the session lists its receipt and would answer it, and a claim whose
/// verb cannot be judged stays with it and says so.
#[tokio::test]
async fn the_loop_settles_nothing_under_a_verb_that_runs() {
	let (scratch, rooms, store, ledger) = rig("bot-actions-live-verb");
	let root = store.root();
	let asked = Asked {
		conversation: ConversationId::new("c1"),
		kind: Kind::Direct,
		triggers: vec![Trigger {
			seq: Seq(1),
			event: Cursor::new("e1").unwrap(),
			line: "l1".into(),
			from: None,
			text: "line 1".into(),
			files: Vec::new(),
		}],
	};
	let id = ledger.borrow_mut().begin(&store, asked).unwrap();
	let (live, unjudged) = (operation(1), operation(2));
	note(root, &live, &Action::new(id, What::Say { to: Place::Here })).unwrap();
	note(root, &unjudged, &turn_of(id.0, None)).unwrap();
	std::fs::write(scratch.join("session/held-actions"), format!("{live}\n{unjudged}\n")).unwrap();
	std::fs::write(scratch.join("session/action-answers"), "kept\nkept\n").unwrap();
	let listed = settle(&rooms, &store, &ledger, &mut Strays::default()).await.unwrap();
	let calls = std::fs::read_to_string(scratch.join("session/calls.jsonl")).unwrap_or_default();
	assert!(!calls.contains("settle-action"), "the loop asked under a verb: {calls}");
	assert_eq!(held(&scratch), format!("{live}\n{unjudged}\n"));
	for operation in [&live, &unjudged] {
		let claim: Action = ACTIONS.read(root, operation, State::Live).unwrap().unwrap();
		assert_eq!(claim.outcome, None);
	}
	assert!(
		listed
			.waiting
			.as_deref()
			.is_some_and(|why| why.contains("cannot be told")),
		"{listed:?}"
	);
}

/// The old access's last list learns how a running turn's action ended and
/// writes it into the claim, as the serving loop does, so the turn's next run
/// is told.
#[tokio::test]
async fn the_last_list_writes_the_outcome_of_a_running_turns_claim() {
	let (scratch, rooms, store, ledger) = rig("bot-actions-last");
	let root = store.root();
	let asked = Asked {
		conversation: ConversationId::new("c1"),
		kind: Kind::Direct,
		triggers: vec![Trigger {
			seq: Seq(1),
			event: Cursor::new("e1").unwrap(),
			line: "l1".into(),
			from: None,
			text: "line 1".into(),
			files: Vec::new(),
		}],
	};
	let id = ledger.borrow_mut().begin(&store, asked).unwrap();
	let said = operation(1);
	note(root, &said, &Action::new(id, What::Say { to: Place::Here })).unwrap();
	std::fs::write(scratch.join("session/held-actions"), format!("{said}\n")).unwrap();
	std::fs::write(scratch.join("session/action-answers"), "kept\n").unwrap();
	let snapshot = ledger.borrow().clone();
	last(&rooms, &store, &snapshot).await.unwrap();
	let claim: Action = ACTIONS.read(root, &said, State::Live).unwrap().unwrap();
	assert_eq!(claim.outcome, Some(Outcome::Posted(Standing::Whole)));
}

fn rig(label: &str) -> (Scratch, Files, Store, RefCell<Ledger>) {
	let scratch = Scratch::create(label);
	let session = scratch.join("session");
	std::fs::create_dir_all(&session).unwrap();
	let store = Store::open(&scratch.join("bot")).unwrap();
	store
		.write_bytes(
			rooms_application::archive::identity::FILE,
			&rooms_application::archive::identity::Identity::new([1; 32], [3; 16]).encode(),
		)
		.unwrap();
	let ledger = Ledger::start(&store, Cursor::start()).unwrap();
	(scratch, Files::open(&session), store, RefCell::new(ledger))
}

fn held(scratch: &Scratch) -> String {
	std::fs::read_to_string(scratch.join("session/held-actions")).unwrap()
}

/// Every listed action no owner settles is settled by the session's answer:
/// a pending one is asked about again, a kept one frees its place, and an
/// unknown one has its receipt given back, whether or not a claim names it.
/// A claim of a turn that ended is removed. A line the ledger records is
/// never asked about.
#[tokio::test]
async fn the_list_settles_each_unowned_action_by_the_sessions_answer() {
	let (scratch, rooms, store, ledger) = rig("bot-actions-list");
	let root = store.root();
	let listed: String = (1..=5).map(|index| format!("{}\n", operation(index))).collect();
	std::fs::write(scratch.join("session/held-actions"), listed).unwrap();
	note(root, &operation(4), &turn(9)).unwrap();
	ledger.borrow_mut().leave(&store, &operation(5)).unwrap();
	std::fs::write(scratch.join("session/action-answers"), "pending\nkept\nunknown\nkept\n").unwrap();
	std::fs::write(scratch.join("session/release-answers"), "released\n").unwrap();
	let mut strays = Strays::default();
	let first = settle(&rooms, &store, &ledger, &mut strays).await.unwrap();
	assert_eq!(
		first,
		Listed {
			pending: true,
			unsettled: 0,
			..Listed::default()
		}
	);
	assert_eq!(ACTIONS.names(root).unwrap().len(), 0, "the ended turn's claim is gone");
	assert_eq!(held(&scratch), format!("{}\n{}\n", operation(1), operation(5)));
	let calls = std::fs::read_to_string(scratch.join("session/calls.jsonl")).unwrap();
	assert_eq!(calls.matches("settle-action").count(), 4, "{calls}");
	assert_eq!(calls.matches("release-action").count(), 1, "{calls}");
	assert!(!calls.contains(&operation(5)), "the ledger's line is its own: {calls}");
	std::fs::write(scratch.join("session/action-answers"), "kept\n").unwrap();
	let second = settle(&rooms, &store, &ledger, &mut strays).await.unwrap();
	assert_eq!(
		second,
		Listed {
			pending: false,
			unsettled: 0,
			..Listed::default()
		}
	);
	assert_eq!(held(&scratch), format!("{}\n", operation(5)));
	assert_eq!(ledger.borrow().left(), 1, "a listed line's record stays");
	std::fs::write(scratch.join("session/held-actions"), "").unwrap();
	settle(&rooms, &store, &ledger, &mut strays).await.unwrap();
	assert_eq!(
		ledger.borrow().left(),
		0,
		"a line's receipt the session no longer lists is not counted"
	);
	let restarted = Ledger::load(&store).unwrap().unwrap();
	assert_eq!(restarted.left(), 0, "the dropped record was written");
}

/// An action the session cannot settle and will not take back is counted
/// while the session lists it, and asked about no more.
#[tokio::test]
async fn an_action_the_session_will_not_take_back_is_counted_once() {
	let (scratch, rooms, store, ledger) = rig("bot-actions-left");
	std::fs::write(scratch.join("session/held-actions"), format!("{}\n", operation(6))).unwrap();
	std::fs::write(scratch.join("session/action-answers"), "unknown\n").unwrap();
	std::fs::write(scratch.join("session/release-answers"), "refused\n").unwrap();
	let mut strays = Strays::default();
	let first = settle(&rooms, &store, &ledger, &mut strays).await.unwrap();
	assert_eq!(
		first,
		Listed {
			pending: false,
			unsettled: 1,
			..Listed::default()
		}
	);
	let again = settle(&rooms, &store, &ledger, &mut strays).await.unwrap();
	assert_eq!(again, first);
	let calls = std::fs::read_to_string(scratch.join("session/calls.jsonl")).unwrap();
	assert_eq!(calls.matches("settle-action").count(), 1, "{calls}");
	std::fs::write(scratch.join("session/held-actions"), "").unwrap();
	let gone = settle(&rooms, &store, &ledger, &mut strays).await.unwrap();
	assert_eq!(
		gone,
		Listed::default(),
		"a receipt the session no longer lists is not counted"
	);
}

/// A restart in the middle of a reply finds its first line finished by its
/// echo while another access held the receipt, and its second sent and not
/// yet kept. The ledger read back from disk names both as the delivery
/// path's, so the serving loop never asks about either, though the session
/// lists both as held, and settles only the action no owner names.
#[tokio::test]
async fn a_restart_mid_delivery_leaves_the_sent_and_replaced_lines_to_their_delivery() {
	let (scratch, rooms, store, ledger) = rig("bot-actions-mid-delivery");
	let (replaced, sent, stray) = (operation(1), operation(2), operation(3));
	{
		let mut ledger = ledger.borrow_mut();
		let asked = Asked {
			conversation: ConversationId::new("c1"),
			kind: Kind::Direct,
			triggers: vec![Trigger {
				seq: Seq(1),
				event: Cursor::new("e1").unwrap(),
				line: "l1".into(),
				from: None,
				text: "line 1".into(),
				files: Vec::new(),
			}],
		};
		let id = ledger.begin(&store, asked).unwrap();
		let parts = [&replaced, &sent]
			.into_iter()
			.map(|operation| Part {
				operation: operation.clone(),
				text: "text".into(),
			})
			.collect();
		ledger.answer(&store, id, Content::Answer, parts).unwrap();
		let line = Replaced {
			operation: replaced.clone(),
			base: Base(1),
			conversation: ConversationId::new("c1"),
			text: "text".into(),
		};
		ledger.part_replaced(&store, id, line).unwrap();
		let attempt = Attempt::Sent {
			base: Base(1),
			after: Cursor::start(),
			looks: 0,
		};
		ledger.attempt(&store, id, attempt).unwrap();
	}
	let restarted = RefCell::new(Ledger::load(&store).unwrap().unwrap());
	assert_eq!(restarted.borrow().sent(), std::slice::from_ref(&sent));
	let listed = format!("{replaced}\n{sent}\n{stray}\n");
	std::fs::write(scratch.join("session/held-actions"), listed).unwrap();
	std::fs::write(scratch.join("session/action-answers"), "kept\n").unwrap();
	settle(&rooms, &store, &restarted, &mut Strays::default())
		.await
		.unwrap();
	let calls = std::fs::read_to_string(scratch.join("session/calls.jsonl")).unwrap();
	assert_eq!(calls.matches("settle-action").count(), 1, "{calls}");
	assert!(calls.contains(&stray), "{calls}");
	assert!(
		!calls.contains(&replaced) && !calls.contains(&sent),
		"the loop asked about a line its delivery owns: {calls}"
	);
}

/// The session lists a direct-message open's receipt while it keeps a place.
/// Its note owns it, so the serving loop never asks about it as an action.
#[tokio::test]
async fn a_listed_open_is_left_to_its_note() {
	let (scratch, rooms, store, ledger) = rig("bot-actions-open");
	let (open, stray) = (operation(1), operation(2));
	let introduction = rooms_services::session::attached::Introduction {
		directory: "d".into(),
		peer: "ann".into(),
		registration: "r".into(),
	};
	let noted = crate::bot::opens::Open {
		base: Base(3),
		introduction,
		conversation: ConversationId::new("c"),
		turn: TurnId(0),
	};
	crate::bot::opens::note(store.root(), &open, &noted).unwrap();
	std::fs::write(scratch.join("session/held-opens"), format!("{open}\n")).unwrap();
	std::fs::write(scratch.join("session/held-actions"), format!("{stray}\n")).unwrap();
	std::fs::write(scratch.join("session/action-answers"), "kept\n").unwrap();
	settle(&rooms, &store, &ledger, &mut Strays::default()).await.unwrap();
	let calls = std::fs::read_to_string(scratch.join("session/calls.jsonl")).unwrap();
	assert!(calls.contains(&stray), "the stray action was asked about: {calls}");
	assert!(!calls.contains(&open), "the loop asked about a noted open: {calls}");
}

/// The list decides the ledger's records of lines the session would not take
/// back. A record from before the list that the list does not name goes. A
/// record written while the list is asked may name a receipt the list
/// predates, so it stays until the next list decides it.
#[tokio::test]
async fn a_left_record_written_while_the_list_is_asked_waits_for_the_next_list() {
	let (scratch, rooms, store, ledger) = rig("bot-actions-left-records");
	let session = scratch.join("session");
	ledger.borrow_mut().leave(&store, &operation(1)).unwrap();
	std::fs::write(session.join("held-answers"), "wait\n").unwrap();
	let mut strays = Strays::default();
	let write = async {
		while !session.join("held-asked").exists() {
			tokio::task::yield_now().await;
		}
		ledger.borrow_mut().leave(&store, &operation(2)).unwrap();
		std::fs::write(session.join("held-go"), "").unwrap();
	};
	let (listed, ()) = tokio::join!(settle(&rooms, &store, &ledger, &mut strays), write);
	listed.unwrap();
	assert_eq!(
		ledger.borrow().left_lines(),
		[operation(2)],
		"the record from before the list went, and the one written during it stayed"
	);
	settle(&rooms, &store, &ledger, &mut strays).await.unwrap();
	assert!(ledger.borrow().left_lines().is_empty(), "the next list decided it");
}

/// An action whose settling waits on a cause, such as a committed line the
/// bot cannot keep yet, is named in the list's answer, so the serving loop can
/// show an operator why its line is still unkept. An action whose work is
/// merely running is not a failure to show.
#[tokio::test]
async fn an_action_waiting_on_a_cause_is_named_and_one_still_running_is_not() {
	let (scratch, rooms, store, ledger) = rig("bot-actions-waiting");
	std::fs::write(scratch.join("session/held-actions"), format!("{}\n", operation(7))).unwrap();
	std::fs::write(scratch.join("session/action-answers"), "pending\nunreachable\nkept\n").unwrap();
	let mut strays = Strays::default();
	let running = settle(&rooms, &store, &ledger, &mut strays).await.unwrap();
	assert!(running.pending && running.waiting.is_none(), "{running:?}");
	let waiting = settle(&rooms, &store, &ledger, &mut strays).await.unwrap();
	assert!(waiting.pending, "{waiting:?}");
	let said = waiting.waiting.expect("the cause is named");
	assert!(
		said.contains(&operation(7)) && said.contains("the stand-in injected unreachable"),
		"{said}"
	);
	let kept = settle(&rooms, &store, &ledger, &mut strays).await.unwrap();
	assert_eq!(kept, Listed::default());
}

/// One access can serve a membership worker, another bot and us. Every
/// receipt remains visible in the access inventory. Only our action reaches
/// the settlement path, both in the sweep and in a replacement's last list.
#[tokio::test]
async fn only_actions_issued_by_this_bot_are_settled() {
	for replacing in [false, true] {
		let (scratch, rooms, store, ledger) = rig("bot-actions-shared-access");
		let ours = operation(1);
		let (_, our_tag) = ours.split_once('-').expect("signed operation has a tag");
		let wrong_bot = crate::bot::identity::sign(&[9; 16], &format!("{:032x}", 2));
		let foreign = [
			format!("membership-{}:2", "e".repeat(32)),
			format!("{:032x}", 3),
			wrong_bot,
			format!("{:032x}-{our_tag}", 4),
		];
		let remaining = foreign.join("\n") + "\n";
		std::fs::write(scratch.join("session/held-actions"), format!("{ours}\n{remaining}")).unwrap();
		std::fs::write(scratch.join("session/action-answers"), "kept\n").unwrap();
		if replacing {
			let snapshot = ledger.borrow().clone();
			last(&rooms, &store, &snapshot).await.unwrap();
		} else {
			settle(&rooms, &store, &ledger, &mut Strays::default()).await.unwrap();
		}
		assert_eq!(held(&scratch), remaining);
	}
}

#[tokio::test]
async fn both_lists_refuse_to_discard_receipts_if_the_identity_was_lost() {
	let (scratch, rooms, store, ledger) = rig("bot-lost-receipt-key");
	let our_receipt = format!("{}\n", operation(1));
	std::fs::write(scratch.join("session/held-actions"), &our_receipt).unwrap();
	std::fs::remove_file(store.root().join(rooms_application::archive::identity::FILE)).unwrap();
	assert!(settle(&rooms, &store, &ledger, &mut Strays::default()).await.is_err());
	let snapshot = ledger.into_inner();
	assert!(last(&rooms, &store, &snapshot).await.is_err());
	assert_eq!(held(&scratch), our_receipt);
}
