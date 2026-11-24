//! Giving an open's receipt back. An open the bot gives up on is given back
//! when the session will take it, a release the session cannot answer yet is
//! asked again without sending the open, and a note being given back counts
//! as unsettled until it drops.
use super::*;

/// An open the bot gives up on is released when the session will give its
/// receipt back, so no note is left holding a place, and it is left unsettled
/// when the session will not.
#[tokio::test]
async fn a_given_up_open_gives_its_receipt_back_when_the_session_allows_it() {
	let (_scratch, session, rooms, store) = rig("bot-opens-release");
	for index in 1..=2 {
		put(&store, index);
	}
	answer(&session, "unknown\nunknown\n");
	std::fs::write(session.join("release-answers"), "released\nrefused\n").unwrap();
	let looked = look(
		&rooms,
		&store,
		&Pass::Serving,
		&BTreeSet::new(),
		&mut Waiting::default(),
	)
	.await
	.unwrap();
	assert_eq!((looked.unsettled_now, counts(&store).0), (1, 1), "{looked:?}");
	assert_eq!(notes(&store), (Vec::new(), vec!["2".into()]));
}

/// An open answered as a revoked access settles, because the session gives
/// its receipts back. One answered as an access the session no longer holds
/// says nothing of its receipt, so it gives up, its receipt is asked back,
/// and a refusal keeps the note. Other failures wait.
#[test]
fn an_open_answered_revoked_settles_denied_gives_up_and_other_failures_wait() {
	let said = verdict(Err(RoomsError::new(RoomsErrorKind::Revoked, "gone")));
	assert!(matches!(said, Verdict::Settled(_)));
	let said = verdict(Err(RoomsError::new(RoomsErrorKind::Denied, "out of scope")));
	assert!(matches!(said, Verdict::GiveUp { .. }));
	for kind in [RoomsErrorKind::Unreachable, RoomsErrorKind::Paused] {
		let said = verdict(Err(RoomsError::new(kind, "later")));
		assert!(matches!(said, Verdict::Later(_)), "{kind:?}");
	}
}

/// A request to give a receipt back that the session cannot answer yet is no
/// verdict: the note stays given up and the next look asks for the receipt
/// again, never sending the open again. Only a refusal leaves it unsettled,
/// and an access the session ended settles it.
#[tokio::test]
async fn only_a_refused_release_leaves_a_given_up_open_unsettled() {
	let (_scratch, session, rooms, store) = rig("bot-opens-release-kinds");
	put(&store, 1);
	let serving = Pass::Serving;
	let mut waiting = Waiting::default();
	for later in ["unreachable", "paused"] {
		answer(&session, "unknown\n");
		std::fs::write(session.join("release-answers"), format!("{later}\n")).unwrap();
		let looked = look(&rooms, &store, &serving, &BTreeSet::new(), &mut waiting)
			.await
			.unwrap();
		// The note being given back counts as unsettled until it drops.
		assert_eq!(
			(looked.pending, looked.unsettled_now, counts(&store).0),
			(true, 0, 1),
			"{later}: {looked:?}"
		);
		assert_eq!(notes(&store), (Vec::new(), Vec::new()), "{later}");
		assert_eq!(giving(&store), ["1"], "{later}");
		assert_eq!(settle_asks(&session), 1, "a given-up open is never sent again");
	}
	answer(&session, "unknown\n");
	std::fs::write(session.join("release-answers"), "released\n").unwrap();
	assert!(
		!look(&rooms, &store, &serving, &BTreeSet::new(), &mut waiting)
			.await
			.unwrap()
			.pending
	);
	assert_eq!(
		notes(&store),
		(Vec::new(), Vec::new()),
		"asked again, the session gave it back"
	);
	put(&store, 2);
	answer(&session, "unknown\n");
	std::fs::write(session.join("release-answers"), "revoked\n").unwrap();
	look(&rooms, &store, &serving, &BTreeSet::new(), &mut waiting)
		.await
		.unwrap();
	assert_eq!(notes(&store), (Vec::new(), Vec::new()), "an ended access settles it");
	put(&store, 4);
	answer(&session, "unknown\n");
	std::fs::write(session.join("release-answers"), "denied\n").unwrap();
	let looked = look(&rooms, &store, &serving, &BTreeSet::new(), &mut waiting)
		.await
		.unwrap();
	assert_eq!(
		(looked.unsettled_now, notes(&store).1),
		(1, vec!["4".to_owned()]),
		"a denied access's receipt is not shown to be released"
	);
	put(&store, 3);
	answer(&session, "unknown\n");
	std::fs::write(session.join("release-answers"), "refused\n").unwrap();
	let looked = look(&rooms, &store, &serving, &BTreeSet::new(), &mut waiting)
		.await
		.unwrap();
	assert_eq!((looked.unsettled_now, counts(&store).0), (1, 2));
	assert_eq!(notes(&store), (Vec::new(), vec!["3".into(), "4".into()]));
}

/// An open the session answers unknown is given back. A release answered
/// running leaves the note given up, the next look asks for the receipt again
/// without sending the open, and the session's release then forgets it.
#[tokio::test]
async fn an_unknown_open_whose_release_answers_running_is_asked_again() {
	let (_scratch, session, rooms, store) = rig("bot-opens-running");
	put(&store, 1);
	let serving = Pass::Serving;
	let mut waiting = Waiting::default();
	answer(&session, "unknown\n");
	std::fs::write(session.join("release-answers"), "executor-running\n").unwrap();
	let looked = look(&rooms, &store, &serving, &BTreeSet::new(), &mut waiting)
		.await
		.unwrap();
	// The note being given back still holds its place, so status counts it.
	assert_eq!((looked.pending, counts(&store).0), (true, 1), "{looked:?}");
	assert_eq!(notes(&store), (Vec::new(), Vec::new()));
	assert_eq!(giving(&store), ["1"]);
	std::fs::write(session.join("release-answers"), "released\n").unwrap();
	look(&rooms, &store, &serving, &BTreeSet::new(), &mut waiting)
		.await
		.unwrap();
	assert_eq!(notes(&store), (Vec::new(), Vec::new()));
	assert!(giving(&store).is_empty());
	assert_eq!(counts(&store).0, 0);
	assert_eq!(settle_asks(&session), 1, "a given-up open is never sent again");
}
