//! How a reply reaches the session: long answers as several lines, sends
//! whose outcome is unknown, refusals, and a bot killed between lines.
use super::rig::{Rig, eventually};
use serde_json::{Value, json};
use std::collections::BTreeSet;

const MAX_LINE_BYTES: usize = 8192;

fn texts(sent: &[Value]) -> Vec<String> {
	sent.iter()
		.map(|line| line["text"].as_str().unwrap().to_owned())
		.collect()
}

fn operations(sent: &[Value]) -> Vec<String> {
	sent.iter()
		.map(|line| line["operation"].as_str().unwrap().to_owned())
		.collect()
}

/// Every character of `text` except line breaks, in order.
fn without_breaks(text: &str) -> String {
	text.chars().filter(|c| *c != '\n').collect()
}

#[test]
fn a_long_answer_is_posted_as_several_lines_in_order() {
	let rig = Rig::new("bot-long");
	let bot = rig.serve(json!({}), None);
	rig.direct(1, "c1", "long:20000");
	rig.wait_for_cursor(1);
	assert!(bot.stop().success(), "the bot exited with a failure");
	let sent = rig.sent();
	assert_eq!(sent.len(), 3, "{:?}", texts(&sent));
	assert!(texts(&sent).iter().all(|text| text.len() <= MAX_LINE_BYTES));
	assert!(texts(&sent)[0].starts_with("p0 ") && texts(&sent)[1].starts_with("p8 "));
	let posted: usize = texts(&sent).iter().map(|text| without_breaks(text).len()).sum();
	assert_eq!(posted, 20000 - 2 * 19, "only the paragraph breaks between lines may go");
	let ops: BTreeSet<_> = operations(&sent).into_iter().collect();
	assert_eq!(ops.len(), 3, "two lines shared an operation");
}

#[test]
fn an_answer_past_eight_lines_is_cut_with_a_notice() {
	let rig = Rig::new("bot-too-long");
	let bot = rig.serve(json!({}), None);
	rig.direct(1, "c1", "long:100000");
	rig.wait_for_cursor(1);
	assert!(bot.stop().success(), "the bot exited with a failure");
	let sent = texts(&rig.sent());
	assert_eq!(sent.len(), 8);
	assert!(sent.iter().all(|text| text.len() <= MAX_LINE_BYTES));
	assert!(sent[7].ends_with("ran past eight lines.]"), "{:?}", sent[7]);
}

#[test]
fn a_bot_killed_between_the_lines_of_a_reply_never_repeats_one() {
	let rig = Rig::new("bot-long-killed");
	let mut bot = rig.serve(json!({}), Some("after-send@2"));
	rig.direct(1, "c1", "long:20000");
	assert!(
		!bot.process.wait().success(),
		"the bot was not killed after its second line"
	);
	assert_eq!(rig.sent().len(), 2);

	let bot = rig.serve(json!({}), None);
	rig.wait_for_cursor(1);
	assert!(bot.stop().success(), "the bot exited with a failure");
	let sent = rig.sent();
	assert_eq!(sent.len(), 3, "a line was repeated or lost: {:?}", texts(&sent));
	let sends = rig.operations("send");
	assert_eq!(sends.len(), 3, "the unrecorded second line was sent again: {sends:?}");
	assert_eq!(operations(&sent), sends);
	assert_eq!(
		rig.operations("observe"),
		[sends[1].clone()],
		"the restart did not look at the unrecorded line under its operation"
	);
	assert_eq!(rig.operations("keep"), sends, "every posted line is kept");
}

#[test]
fn a_refused_reply_is_replaced_by_one_failure_line_under_a_new_operation() {
	let rig = Rig::new("bot-refused-send");
	rig.send_faults(&["refused"]);
	let bot = rig.serve(json!({}), None);
	rig.direct(1, "c1", "reply:never posted");
	rig.wait_for_cursor(1);
	assert!(bot.stop().success(), "the bot exited with a failure");
	let sent = rig.sent();
	assert_eq!(sent.len(), 1);
	assert!(
		texts(&sent)[0].starts_with("I could not answer that: the session refused my reply"),
		"{:?}",
		texts(&sent)
	);
	let sends = rig.operations("send");
	assert_eq!(sends.len(), 2);
	assert_ne!(sends[0], sends[1], "the failure line reused the refused operation");
	assert_eq!(operations(&sent), [sends[1].clone()]);
	assert!(rig.log().contains("the stand-in injected refused"), "{}", rig.log());
	assert_eq!(
		rig.status()["status"]["access"],
		"active",
		"a refused line was read as refused access"
	);
}

/// Send one reply against `faults` and return the calls it took, as
/// `(call, operation)` pairs, once the turn is finished.
fn delivered(rig: &Rig, at: u64, faults: &[&str]) -> Vec<(String, String)> {
	let before = rig.calls().len();
	rig.send_faults(faults);
	rig.direct(at, &format!("c{at}"), &format!("reply:line {at}"));
	rig.wait_for_cursor(at);
	rig.call_log()[before..]
		.iter()
		.map(|(call, operation, _)| (call.clone(), operation.clone()))
		.collect()
}

#[test]
fn a_send_whose_outcome_is_unknown_is_looked_at_again_under_the_same_operation_and_base() {
	let rig = Rig::new("bot-unsettled");
	let bot = rig.serve(json!({}), None);
	let calls = |names: &[&str], op: &str| -> Vec<(String, String)> {
		names.iter().map(|name| ((*name).to_owned(), op.to_owned())).collect()
	};

	let found = delivered(&rig, 1, &["unreachable"]);
	assert_eq!(found, calls(&["send", "observe", "send", "keep"], &found[0].1));

	let found = delivered(&rig, 2, &["uncertain"]);
	assert_eq!(found, calls(&["send", "observe", "keep"], &found[0].1));

	let found = delivered(&rig, 3, &["pending", "pending"]);
	assert_eq!(found, calls(&["send", "observe", "observe", "keep"], &found[0].1));

	// The session never received this one and activity shows no echo, so the
	// same operation goes out again at the same base, once.
	let found = delivered(&rig, 4, &["lost"]);
	assert_eq!(found, calls(&["send", "observe", "send", "keep"], &found[0].1));

	// Its receipt cannot say, and its echo shows it posted. The session will
	// not keep a line whose send never settled, so its receipt is released.
	let found = delivered(&rig, 5, &["unknown"]);
	assert_eq!(found, calls(&["send", "keep", "release"], &found[0].1));

	eventually("the sending error to clear", || {
		rig.status()["status"]["last_error"].is_null().then_some(())
	});
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(texts(&rig.sent()), ["line 1", "line 2", "line 3", "line 4", "line 5"]);
	let mut bases = rig.call_log();
	bases.dedup_by(|later, earlier| later.1 == earlier.1 && later.2 == earlier.2);
	assert_eq!(
		bases.len(),
		5,
		"an operation was sent or observed at a second base: {bases:?}"
	);
	assert_eq!(rig.status()["status"]["unconfirmed"], 0);
}

/// The send never reached the session, and the workspace moved on before
/// the resend at its base, so that operation can never commit.
const FENCED_OUT: [&str; 3] = ["lost", "ok", "conflict"];
/// The send never reached the session, which holds no receipt for it.
const LOST: [&str; 2] = ["lost", "ok"];

#[test]
fn a_missing_receipt_is_sent_again_only_after_a_complete_read_finds_no_echo() {
	let rig = Rig::new("bot-fenced-out");
	let bot = rig.serve(json!({}), None);
	let found = delivered(&rig, 1, &FENCED_OUT);
	let (old, new) = (&found[0].1, &found[3].1);
	let names: Vec<_> = found.iter().map(|(call, _)| call.as_str()).collect();
	assert_eq!(names, ["send", "observe", "send", "send", "keep"], "{found:?}");
	assert!(found[..3].iter().all(|(_, op)| op == old) && found[3..].iter().all(|(_, op)| op == new));
	assert_ne!(old, new, "the refused operation was sent again");
	// Across a session restart activity cannot say whether the line posted,
	// and a missing receipt says nothing, so the line is never sent again.
	rig.restart_echoes();
	let found = delivered(&rig, 2, &LOST);
	let names: Vec<_> = found.iter().map(|(call, _)| call.as_str()).collect();
	assert_eq!(names, ["send", "observe", "release"], "{found:?}");
	let status = rig.status();
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(texts(&rig.sent()), ["line 1"]);
	assert_eq!(status["status"]["unconfirmed"], 1);
	// The give-up shows in status until a later line commits.
	let problem = &status["status"]["last_error"];
	assert_eq!(problem["during"], "sending", "{status}");
	assert!(
		problem["message"]
			.as_str()
			.unwrap()
			.contains("cannot say whether operation"),
		"{status}"
	);
}

/// A send the session paced was never dispatched, so it goes out again at
/// its base without a look, even where activity could not tell whether it
/// posted.
#[test]
fn a_paced_send_goes_out_again_at_its_base_and_is_never_given_up() {
	let rig = Rig::new("bot-paced");
	let bot = rig.serve(json!({}), None);
	rig.restart_echoes();
	let found = delivered(&rig, 1, &["paced"]);
	let names: Vec<_> = found.iter().map(|(call, _)| call.as_str()).collect();
	assert_eq!(names, ["send", "send", "keep"], "{found:?}");
	assert!(found.iter().all(|(_, op)| op == &found[0].1), "{found:?}");
	let status = rig.status();
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(texts(&rig.sent()), ["line 1"]);
	assert_eq!(status["status"]["unconfirmed"], 0);
}

/// A paced first send keeps its first-send meaning, so a conflict after the
/// wait proves nothing posted and the line goes out under a new operation,
/// even where activity could not tell whether it posted.
#[test]
fn a_paced_first_send_that_meets_a_conflict_goes_out_under_a_new_operation() {
	let rig = Rig::new("bot-paced-conflict");
	let bot = rig.serve(json!({}), None);
	rig.restart_echoes();
	let found = delivered(&rig, 1, &["paced", "conflict"]);
	let names: Vec<_> = found.iter().map(|(call, _)| call.as_str()).collect();
	assert_eq!(names, ["send", "send", "send", "keep"], "{found:?}");
	assert_eq!(found[0].1, found[1].1, "the paced send went out under a new operation");
	assert_ne!(found[1].1, found[2].1, "the refused operation was sent again");
	let status = rig.status();
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(texts(&rig.sent()), ["line 1"]);
	assert_eq!(status["status"]["unconfirmed"], 0);
}

#[test]
fn a_line_contested_past_the_reissue_bound_still_posts_once_and_never_becomes_a_failure_line() {
	let rig = Rig::new("bot-contested");
	let bot = rig.serve(json!({}), None);
	let found = delivered(&rig, 1, &["conflict"; 5]);
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(texts(&rig.sent()), ["line 1"]);
	let sends: Vec<_> = found
		.iter()
		.filter(|(call, _)| call == "send")
		.map(|(_, op)| op)
		.collect();
	assert_eq!(sends.len(), 6, "{found:?}");
	let distinct: BTreeSet<_> = sends.iter().collect();
	assert_eq!(distinct.len(), 6, "a refused operation was sent again: {found:?}");
}

#[test]
fn a_missing_receipt_activity_cannot_vouch_for_is_given_up_on_and_released() {
	let rig = Rig::new("bot-unknowable");
	let bot = rig.serve(json!({}), None);
	rig.lose_echoes();
	let found = delivered(&rig, 1, &LOST);
	let names: Vec<_> = found.iter().map(|(call, _)| call.as_str()).collect();
	assert_eq!(
		names,
		["send", "observe", "release"],
		"a send activity could not vouch for went out again"
	);
	let status = rig.status();
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert!(rig.sent().is_empty());
	assert_eq!(status["status"]["unconfirmed"], 1);
	assert_eq!(status["status"]["open_turns"], 0, "the conversation stayed busy");
	assert!(rig.log().contains("cannot say whether operation"), "{}", rig.log());
}

/// Each path that stops caring about a receipt releases it, so rounds past
/// the session's receipt places never bring it to refuse a send.
#[test]
fn receipts_given_up_on_or_not_kept_are_released_round_after_round() {
	use rooms_application::content::session::custody::MAX_EFFECTS;
	let rig = Rig::new("bot-released");
	let bot = rig.serve(json!({}), None);
	let rounds = MAX_EFFECTS as u64 + 2;
	for at in 1..=rounds {
		// Posted, but never settled, so the session will not keep it.
		delivered(&rig, at, &["unknown"]);
	}
	for at in rounds + 1..=2 * rounds {
		// Never posted and never settled, so it is given up on.
		delivered(&rig, at, &["vanished"]);
	}
	let after = 2 * rounds + 1;
	delivered(&rig, after, &[]);
	let status = rig.status();
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(rig.sent().len() as u64, rounds + 1, "{:?}", texts(&rig.sent()));
	assert_eq!(status["status"]["unconfirmed"], rounds);
	assert!(!rig.log().contains("receipts are full"), "{}", rig.log());
	assert!(
		rig.receipts().iter().all(|receipt| receipt["status"] != "unknown"),
		"{:?}",
		rig.receipts()
	);
}
