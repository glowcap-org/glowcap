//! Noted opens settle through the stand-in session. A settled answer removes
//! its note, and a pending one is looked at again and never given up. Evidence
//! leaves a note unsettled, and so does an unreadable note. The old access's last
//! look settles what it can and leaves the rest as it is. A note past the
//! bound, half the session's receipt places counting the unsettled ones, is
//! refused.
#![cfg(feature = "test-support")]
use super::look::LEFT_UNSETTLED;
use super::note::{GIVING, LIVE, UNSETTLED};
use super::*;
use crate::bot::{
	rooms::{RoomsErrorKind, files::Files},
	store,
};
use rooms_testing::scratch::Scratch;

mod giving;

fn operation(index: usize) -> String {
	format!("{index:032x}")
}

fn open_to(peer: &str, conversation: &str) -> Open {
	Open {
		base: Base(3),
		introduction: Introduction {
			directory: "d".into(),
			peer: peer.into(),
			registration: "r".into(),
		},
		conversation: ConversationId::new(conversation),
		turn: TurnId(0),
	}
}

fn open(conversation: &str) -> Open {
	open_to("ann", conversation)
}

/// The open the note under `operation(index)` holds, to a peer of its own so
/// notes together never name one peer.
fn open_at(index: usize) -> Open {
	open_to(&format!("peer{index}"), "c")
}

/// Write the note under `index` as `note` does, without its bound, since a
/// look reads every note there is.
fn put(store: &Store, index: usize) {
	store::write_unleased(
		store.root(),
		OPENS.directory,
		&format!("{}{LIVE}", operation(index)),
		&open("c"),
	)
	.unwrap();
}

fn answer(rooms: &Path, answers: &str) {
	std::fs::write(rooms.join("open-answers"), answers).unwrap();
}

/// The live notes and the unsettled notes, by operation index.
fn notes(store: &Store) -> (Vec<String>, Vec<String>) {
	let mut names: Vec<_> = std::fs::read_dir(store.root().join(OPENS.directory))
		.unwrap()
		.map(|entry| entry.unwrap().file_name().into_string().unwrap())
		.collect();
	names.sort();
	let short = |name: &str| name.trim_start_matches('0').to_owned();
	let live = names
		.iter()
		.filter_map(|name| name.strip_suffix(LIVE))
		.map(short)
		.collect();
	let unsettled = names
		.iter()
		.filter_map(|name| name.strip_suffix(UNSETTLED))
		.map(short)
		.collect();
	(live, unsettled)
}

/// The notes being given back, by operation index.
fn giving(store: &Store) -> Vec<String> {
	let mut names: Vec<_> = std::fs::read_dir(store.root().join(OPENS.directory))
		.unwrap()
		.filter_map(|entry| {
			let name = entry.unwrap().file_name().into_string().unwrap();
			name.strip_suffix(GIVING)
				.map(|name| name.trim_start_matches('0').to_owned())
		})
		.collect();
	names.sort();
	names
}

/// How many times a look asked the session to settle an open.
fn settle_asks(session: &Path) -> usize {
	std::fs::read_to_string(session.join("calls.jsonl"))
		.unwrap_or_default()
		.matches("settle-open")
		.count()
}

/// The serving access's unsettled opens, as status counts them, and the
/// replaced notes the directory holds.
fn counts(store: &Store) -> (u64, u64) {
	let held = OPENS.listed(store.root()).unwrap();
	(held.unsettled_now(), held.replaced)
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
	let serving = Pass::Serving;
	let mut waiting = Waiting::default();
	assert_eq!(
		look(&rooms, &store, &serving, &BTreeSet::new(), &mut waiting)
			.await
			.unwrap(),
		Looked::default()
	);
	for index in 1..=5 {
		put(&store, index);
	}
	std::fs::write(
		store
			.root()
			.join(OPENS.directory)
			.join(format!("{}{LIVE}", operation(6))),
		"{",
	)
	.unwrap();
	answer(&session, "opened\npending\nunknown\npaused\nrefused\n");
	std::fs::write(session.join("release-answers"), "refused\nrefused\n").unwrap();
	let looked = look(&rooms, &store, &serving, &BTreeSet::new(), &mut waiting)
		.await
		.unwrap();
	assert_eq!(
		looked,
		Looked {
			pending: true,
			unsettled_now: 3,
		}
	);
	assert_eq!(counts(&store), (3, 0));
	assert_eq!(
		notes(&store),
		(vec!["2".into(), "4".into()], vec!["3".into(), "5".into(), "6".into()])
	);
	for _ in 0..3 {
		answer(&session, "pending\nunreachable\n");
		let looked = look(&rooms, &store, &serving, &BTreeSet::new(), &mut waiting)
			.await
			.unwrap();
		assert_eq!((looked.pending, looked.unsettled_now, counts(&store).0), (true, 0, 3));
	}
	assert_eq!(notes(&store).0, ["2", "4"], "no number of pending looks gives one up");
	answer(&session, "opened\nreused\n");
	assert!(
		!look(&rooms, &store, &serving, &BTreeSet::new(), &mut waiting)
			.await
			.unwrap()
			.pending
	);
	assert!(notes(&store).0.is_empty(), "each settled note goes");
	let log = std::fs::read_to_string(store.root().join("bot.log")).unwrap();
	assert_eq!(
		log.matches(words::STILL_SETTLING).count(),
		2,
		"a pending open is logged once\n{log}"
	);
	assert!(log.contains(words::COULD_NOT_BE_READ), "{log}");
	assert_eq!(log.matches(LEFT_UNSETTLED).count(), 3, "{log}");
	assert_eq!(counts(&store).0, 3);
}

#[tokio::test]
async fn a_last_look_settles_what_it_can_and_decides_nothing_else() {
	let (_scratch, session, rooms, store) = rig("bot-opens-last");
	for index in 1..=5 {
		put(&store, index);
	}
	answer(&session, "revoked\nunapplied\nunknown\nunreachable\npending\n");
	let looked = look(
		&rooms,
		&store,
		&Pass::Last {
			foreign: BTreeSet::new(),
		},
		&BTreeSet::new(),
		&mut Waiting::default(),
	)
	.await
	.unwrap();
	assert_eq!((looked.pending, looked.unsettled_now, counts(&store).0), (false, 0, 0));
	assert_eq!(
		notes(&store),
		(vec!["3".into(), "4".into(), "5".into()], Vec::new()),
		"the notes it could not settle stay live, as a refused replacement needs"
	);
	assert!(
		!std::fs::read_to_string(session.join("calls.jsonl"))
			.unwrap()
			.contains("release-open"),
		"a last look gives no receipt back"
	);
}

#[test]
fn a_note_past_the_bound_is_refused_and_a_settled_one_goes() {
	let scratch = Scratch::create("bot-opens-bound");
	assert_eq!(MAX_OPENS * 2, MAX_EFFECTS, "opens hold at most half the receipt places");
	for index in 1..=MAX_OPENS {
		note(&scratch, &operation(index), &open_at(index)).unwrap();
	}
	assert_eq!(noted(&scratch, &operation(1)).unwrap(), Some(open_at(1)));
	let past = operation(MAX_OPENS + 1);
	let Err(Error::Usage(refused)) = note(&scratch, &past, &open_at(MAX_OPENS + 1)) else {
		panic!("a note past the bound was kept");
	};
	assert!(refused.contains(&MAX_OPENS.to_string()), "{refused}");
	assert_eq!(noted(&scratch, &past).unwrap(), None, "the refused note is removed");
	forget(&scratch, &operation(1)).unwrap();
	forget(&scratch, &operation(1)).unwrap();
	note(&scratch, &past, &open_at(MAX_OPENS + 1)).unwrap();
	for refused in ["../escape", "not-hex-but-thirty-two-bytes-long", ""] {
		assert!(note(&scratch, refused, &open_at(0)).is_err(), "{refused}");
		assert_eq!(noted(&scratch, refused).unwrap(), None, "{refused}");
	}
}

/// An unsettled open still holds its session receipt, so it counts toward the
/// bound until its note is deleted.
#[test]
fn an_unsettled_note_holds_a_place_until_it_is_deleted() {
	let scratch = Scratch::create("bot-opens-unsettled-bound");
	for index in 1..=MAX_OPENS {
		note(&scratch, &operation(index), &open_at(index)).unwrap();
	}
	for index in 1..=MAX_OPENS {
		assert!(
			OPENS
				.restate(&scratch, &operation(index), State::Live, State::Unsettled)
				.unwrap()
		);
	}
	let past = operation(MAX_OPENS + 1);
	let Err(Error::Usage(refused)) = note(&scratch, &past, &open_at(MAX_OPENS + 1)) else {
		panic!("a note past the bound was kept beside unsettled ones");
	};
	assert!(refused.contains("4 unsettled"), "{refused}");
	let unsettled = scratch
		.join(OPENS.directory)
		.join(format!("{}{UNSETTLED}", operation(1)));
	std::fs::remove_file(unsettled).unwrap();
	note(&scratch, &past, &open_at(MAX_OPENS + 1)).unwrap();
}

/// A note another access sent, unsettled or not, is not counted against the
/// serving access's bound, because the session keeps its receipt under that
/// access.
#[test]
fn a_note_another_access_sent_is_not_counted_against_the_serving_one() {
	let (_scratch, _session, _rooms, store) = rig("bot-opens-replaced");
	let root = store.root();
	for index in 1..=MAX_OPENS {
		note(root, &operation(index), &open_at(index)).unwrap();
		assert!(
			OPENS
				.restate(root, &operation(index), State::Live, State::Unsettled)
				.unwrap()
		);
	}
	for note in unplaced(root).unwrap() {
		note.place(&store, Holder::Another).unwrap();
	}
	note(root, &operation(MAX_OPENS + 1), &open_at(MAX_OPENS + 1)).unwrap();
	assert!(
		OPENS
			.restate(root, &operation(MAX_OPENS + 1), State::Live, State::Unsettled)
			.unwrap()
	);
	let listed = OPENS.listed(root).unwrap();
	assert_eq!((listed.unsettled, listed.replaced), (1, MAX_OPENS as u64));
}

/// The session's answer places a note by name, and the name keeps its other
/// state, so the access that holds the receipt again finds the note as it was.
#[test]
fn a_notes_place_follows_the_sessions_answer_and_keeps_its_other_state() {
	let (_scratch, _session, _rooms, store) = rig("bot-opens-place");
	let root = store.root();
	for index in 1..=3 {
		note(root, &operation(index), &open_at(index)).unwrap();
	}
	assert!(
		OPENS
			.restate(root, &operation(2), State::Live, State::Unsettled)
			.unwrap()
	);
	let files = || {
		let mut names: Vec<_> = std::fs::read_dir(root.join(OPENS.directory))
			.unwrap()
			.map(|entry| {
				entry
					.unwrap()
					.file_name()
					.into_string()
					.unwrap()
					.trim_start_matches('0')
					.to_owned()
			})
			.collect();
		names.sort();
		names
	};
	assert_eq!(files(), ["1.json", "2.json.unsettled", "3.json"]);
	let place = |holder| {
		for note in unplaced(root).unwrap() {
			note.place(&store, holder).unwrap();
		}
	};
	place(Holder::Another);
	assert_eq!(
		files(),
		["1.json.replaced", "2.json.unsettled.replaced", "3.json.replaced"]
	);
	let listed_now = OPENS.listed(root).unwrap();
	assert_eq!(
		(listed_now.live.len(), listed_now.unsettled, listed_now.replaced),
		(0, 0, 3)
	);
	place(Holder::Another);
	assert_eq!(
		files(),
		["1.json.replaced", "2.json.unsettled.replaced", "3.json.replaced"]
	);
	place(Holder::Mine);
	assert_eq!(files(), ["1.json", "2.json.unsettled", "3.json"]);
	place(Holder::Mine);
	assert_eq!(files(), ["1.json", "2.json.unsettled", "3.json"]);
	place(Holder::Nobody);
	assert!(files().is_empty(), "a note the session holds nothing for is dropped");
	let log = std::fs::read_to_string(root.join("bot.log")).unwrap();
	assert_eq!(log.matches(words::HOLDS_NOTHING).count(), 3, "{log}");
}

/// A note another access sent, live or unsettled, is one the serving access
/// cannot settle, so no look touches it and it is not counted against the
/// serving access.
#[tokio::test]
async fn a_live_note_another_access_sent_is_never_looked_at() {
	let (_scratch, session, rooms, store) = rig("bot-opens-replaced-live");
	put(&store, 1);
	put(&store, 2);
	for note in unplaced(store.root()).unwrap() {
		let holder = if note.operation() == operation(2) {
			Holder::Another
		} else {
			Holder::Mine
		};
		note.place(&store, holder).unwrap();
	}
	answer(&session, "opened\nopened\n");
	let looked = look(
		&rooms,
		&store,
		&Pass::Serving,
		&BTreeSet::new(),
		&mut Waiting::default(),
	)
	.await
	.unwrap();
	assert_eq!(counts(&store), (0, 1), "{looked:?}");
	assert_eq!(
		notes(&store),
		(Vec::new(), Vec::new()),
		"only the serving access's note settled, and the other is marked replaced"
	);
	assert!(std::fs::read_dir(store.root().join(OPENS.directory)).unwrap().count() == 1);
	let calls = std::fs::read_to_string(session.join("calls.jsonl")).unwrap();
	assert_eq!(calls.matches("settle-open").count(), 1, "{calls}");
}

/// An open the old access had given up is given back at its last look, so
/// the receipt is not left for an access nobody can serve again: the note goes
/// once the session takes the receipt back, and stays as it is when it refuses.
#[tokio::test]
async fn a_last_look_gives_back_an_open_this_access_had_given_up() {
	let (_scratch, session, rooms, store) = rig("bot-opens-last-giving");
	for index in 1..=2 {
		store::write_unleased(
			store.root(),
			OPENS.directory,
			&format!("{}{GIVING}", operation(index)),
			&open("c"),
		)
		.unwrap();
	}
	let last = Pass::Last {
		foreign: BTreeSet::new(),
	};
	std::fs::write(session.join("release-answers"), "refused\nreleased\n").unwrap();
	look(&rooms, &store, &last, &BTreeSet::new(), &mut Waiting::default())
		.await
		.unwrap();
	assert_eq!(giving(&store), ["1"], "a refused release left the note as it was");
	assert_eq!(notes(&store), (Vec::new(), Vec::new()));
}

/// An old access's last look leaves the notes the session says it did not send.
#[tokio::test]
async fn a_last_look_leaves_the_notes_another_access_sent() {
	let (_scratch, session, rooms, store) = rig("bot-opens-last-foreign");
	for index in 1..=3 {
		put(&store, index);
	}
	answer(&session, "opened\nopened\nopened\n");
	let last = Pass::Last {
		foreign: BTreeSet::from([operation(2)]),
	};
	look(&rooms, &store, &last, &BTreeSet::new(), &mut Waiting::default())
		.await
		.unwrap();
	assert_eq!(notes(&store), (vec!["2".into()], Vec::new()));
}

#[tokio::test]
async fn a_note_of_an_open_turn_is_never_looked_at_and_is_once_its_turn_ends() {
	let (_scratch, session, rooms, store) = rig("bot-opens-owned");
	let mut owned = open("c");
	owned.turn = TurnId(7);
	let name = format!("{}{LIVE}", operation(1));
	store::write_unleased(store.root(), OPENS.directory, &name, &owned).unwrap();
	answer(&session, "opened\n");
	let open_turns = BTreeSet::from([TurnId(7)]);
	for _ in 0..3 {
		let looked = look(&rooms, &store, &Pass::Serving, &open_turns, &mut Waiting::default())
			.await
			.unwrap();
		assert_eq!(looked, Looked::default());
		assert_eq!(notes(&store).0, ["1"], "the turn that wrote it still owns it");
	}
	assert_eq!(
		std::fs::read_to_string(session.join("open-answers")).unwrap(),
		"opened\n",
		"no look asked the session"
	);
	// The turn that wrote it counts against the bound while it owns the note.
	assert_eq!(OPENS.listed(store.root()).unwrap().live.len(), 1);
	let ended = BTreeSet::from([TurnId(8)]);
	look(&rooms, &store, &Pass::Serving, &ended, &mut Waiting::default())
		.await
		.unwrap();
	assert!(notes(&store).0.is_empty(), "once its turn ends the loop settles it");
}

#[test]
fn an_atomic_write_in_flight_is_never_listed_as_a_note() {
	let scratch = Scratch::create("bot-opens-temp");
	let store = Store::open(&scratch.join("bot")).unwrap();
	let directory = store.root().join(OPENS.directory);
	std::fs::create_dir_all(&directory).unwrap();
	let name = operation(1);
	for temporary in [
		format!(".{name}{LIVE}.tmp-1-1"),
		format!(".{name}{UNSETTLED}.tmp-1-1"),
		format!("{name}{LIVE}.tmp-1-1"),
	] {
		std::fs::write(directory.join(temporary), "{").unwrap();
	}
	assert!(!held(store.root()).unwrap());
	put(&store, 2);
	let listed = OPENS.listed(store.root()).unwrap();
	assert_eq!(
		(listed.live, listed.unsettled, listed.replaced),
		(vec![operation(2)], 0, 0)
	);
	assert!(held(store.root()).unwrap());
}

/// Two verbs noting at once with room for one are not both refused, and not
/// both kept: the count and the write are one step.
#[test]
fn two_notes_at_once_with_room_for_one_keep_exactly_one() {
	for round in 0..20 {
		let scratch = Scratch::create(&format!("bot-opens-race-{round}"));
		for index in 1..MAX_OPENS {
			note(&scratch, &operation(index), &open_at(index)).unwrap();
		}
		let barrier = std::sync::Barrier::new(2);
		let answers: Vec<_> = std::thread::scope(|scope| {
			let racing: Vec<_> = [MAX_OPENS, MAX_OPENS + 1]
				.into_iter()
				.map(|index| {
					let (root, barrier): (&Path, _) = (&scratch, &barrier);
					scope.spawn(move || {
						barrier.wait();
						note(root, &operation(index), &open_at(index)).is_ok()
					})
				})
				.collect();
			racing.into_iter().map(|racer| racer.join().unwrap()).collect()
		});
		assert_eq!(
			answers.iter().filter(|kept| **kept).count(),
			1,
			"round {round}: {answers:?}"
		);
		assert_eq!(OPENS.listed(&scratch).unwrap().live.len(), MAX_OPENS, "round {round}");
	}
}

/// A rename of a note takes the lease a count holds, so the count never lists
/// the note under neither name or under both. While a count holds it, the
/// rename waits its short bound, which is far under a verb's, and fails with
/// a transient error the serving loop asks again on, and the note keeps its
/// name.
#[test]
fn a_rename_waits_for_a_count_in_progress() {
	let scratch = Scratch::create("bot-opens-rename-count");
	note(&scratch, &operation(1), &open_at(1)).unwrap();
	let held = OPENS.counting(&scratch).unwrap();
	let began = std::time::Instant::now();
	let refused = OPENS
		.restate(&scratch, &operation(1), State::Live, State::Giving)
		.expect_err("a note was renamed during a count");
	assert!(refused.is_transient(), "{refused}");
	assert!(
		began.elapsed() < super::note::COUNT_WAIT,
		"the loop's rename waited as long as a verb's note does"
	);
	assert_eq!(OPENS.listed(&scratch).unwrap().live, [operation(1)]);
	drop(held);
	assert!(
		OPENS
			.restate(&scratch, &operation(1), State::Live, State::Giving)
			.unwrap(),
		"the note was gone"
	);
	assert_eq!(OPENS.listed(&scratch).unwrap().giving, [operation(1)]);
}

/// A note given up on, or one the session no longer holds a receipt for after
/// its access was revoked, goes at the next start: nobody holds its receipt, so
/// the operator deletes nothing.
#[test]
fn an_unsettled_note_the_session_holds_nothing_for_is_dropped_with_a_log_line() {
	let (_scratch, _session, _rooms, store) = rig("bot-opens-unsettled-nobody");
	let root = store.root();
	note(root, &operation(1), &open("c")).unwrap();
	assert!(
		OPENS
			.restate(root, &operation(1), State::Live, State::Unsettled)
			.unwrap()
	);
	for note in unplaced(root).unwrap() {
		note.place(&store, Holder::Nobody).unwrap();
	}
	assert!(!held(root).unwrap(), "the unsettled note stayed");
	let log = std::fs::read_to_string(root.join("bot.log")).unwrap();
	assert!(log.contains(words::HOLDS_NOTHING), "{log}");
}

/// Two turns noting an open to one peer at once spend one place: the check
/// for a live note to that peer and the write are one step under the lease.
#[test]
fn two_opens_to_one_peer_at_once_note_exactly_one() {
	for round in 0..20 {
		let scratch = Scratch::create(&format!("bot-opens-same-peer-{round}"));
		let barrier = std::sync::Barrier::new(2);
		let answers: Vec<_> = std::thread::scope(|scope| {
			let racing: Vec<_> = [1, 2]
				.into_iter()
				.map(|index| {
					let (root, barrier): (&Path, _) = (&scratch, &barrier);
					scope.spawn(move || {
						barrier.wait();
						note(root, &operation(index), &open("c")).is_ok()
					})
				})
				.collect();
			racing.into_iter().map(|racer| racer.join().unwrap()).collect()
		});
		assert_eq!(
			answers.iter().filter(|kept| **kept).count(),
			1,
			"round {round}: {answers:?}"
		);
		assert_eq!(OPENS.listed(&scratch).unwrap().live.len(), 1, "round {round}");
	}
}

/// An action whose line is still unkept shows its cause in `status.last_error`
/// while the list names it, and the error clears with the keep and not with
/// another source's failure.
#[test]
fn an_unkept_action_shows_its_cause_in_the_status_until_it_is_kept() {
	use crate::bot::status::{Activity, Facts};
	let mut facts = Facts::default();
	let mut shown = None;
	let waiting = action::Listed {
		pending: true,
		waiting: Some("the agent's action under operation x is not settled, and the bot asks again: busy".into()),
		..action::Listed::default()
	};
	assert!(show_waiting(&mut facts, &mut shown, Some(&waiting)));
	let problem = facts.last_error.clone().expect("the cause is shown");
	assert!(problem.message.contains("asks again: busy"), "{problem:?}");
	assert!(
		!show_waiting(&mut facts, &mut shown, Some(&waiting)),
		"unchanged on the next pass"
	);
	assert!(
		!show_waiting(&mut facts, &mut shown, None),
		"a pass that did not list changes nothing"
	);
	assert!(facts.last_error.is_some());
	facts.failed(Activity::Sending, "another failure");
	assert!(show_waiting(&mut facts, &mut shown, Some(&action::Listed::default())));
	assert!(
		facts
			.last_error
			.as_ref()
			.is_some_and(|problem| problem.message == "another failure"),
		"a clear takes only what this loop showed"
	);
	let mut facts = Facts::default();
	let mut shown = None;
	show_waiting(&mut facts, &mut shown, Some(&waiting));
	assert!(show_waiting(&mut facts, &mut shown, Some(&action::Listed::default())));
	assert!(facts.last_error.is_none());
}
