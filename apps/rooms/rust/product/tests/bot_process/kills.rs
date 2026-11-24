//! A bot that dies at each step of posting a reply, and the line it leaves,
//! on the stand-in session. `captp_crashes.rs` and `captp_recovery.rs` repeat
//! these crash points on a real session, so a change to what a crash leaves
//! is made in both.
use super::rig::{Rig, runs};
use super::words;
use serde_json::json;

/// Kill the bot at `point` while it posts a one-line reply, restart it, and
/// return the rig once the turn is finished.
fn killed_at(point: &str, label: &str) -> Rig {
	let rig = Rig::new(label);
	let mut bot = rig.serve(json!({}), Some(point));
	rig.direct(1, "c1", "reply:exactly once");
	// The bot ends itself at the fault point, so the wait is for its exit.
	let status = bot.process.wait();
	assert!(!status.success(), "the bot should have been killed at {point}");
	assert_eq!(rig.sent().len(), 1, "the reply was not sent before {point}");

	let bot = rig.serve(json!({}), None);
	rig.wait_for_cursor(1);
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(rig.sent().len(), 1, "a restart after {point} posted the reply again");
	assert_eq!(rig.sent()[0]["text"], "exactly once");
	assert_eq!(
		runs(&rig.workdir("c1")),
		1,
		"a restart after {point} ran the harness again for an answered turn"
	);
	rig
}

/// The calls of one operation, as `(call, base)` pairs.
fn calls_of(rig: &Rig, operation: &str) -> Vec<(String, u64)> {
	rig.call_log()
		.into_iter()
		.filter(|(_, op, _)| op == operation)
		.map(|(call, _, base)| (call, base))
		.collect()
}

fn call(name: &str, base: u64) -> (String, u64) {
	(name.to_owned(), base)
}

#[test]
fn a_bot_killed_after_the_send_before_the_ledger_observes_the_operation_at_its_base_and_keeps_it() {
	let rig = killed_at("after-send", "bot-after-send");
	let op = rig.sent()[0]["operation"].as_str().unwrap().to_owned();
	assert_eq!(
		calls_of(&rig, &op),
		[call("send", 0), call("observe", 0), call("keep", 0)]
	);
	assert_eq!(rig.receipts()[0]["kept"], true, "the line was never kept");
}

#[test]
fn a_bot_killed_before_its_send_reached_the_session_sends_the_same_operation_once() {
	let rig = Rig::new("bot-before-send");
	let mut bot = rig.serve(json!({}), Some("before-send"));
	rig.direct(1, "c1", "reply:exactly once");
	assert!(!bot.process.wait().success(), "the bot was not killed before its send");
	assert!(rig.sent().is_empty());
	let bot = rig.serve(json!({}), None);
	rig.wait_for_cursor(1);
	assert!(bot.stop().success(), "the bot exited with a failure");
	let sent = rig.sent();
	assert_eq!(sent.len(), 1, "{sent:?}");
	let op = sent[0]["operation"].as_str().unwrap();
	assert_eq!(
		calls_of(&rig, op),
		[call("observe", 0), call("send", 0), call("keep", 0)],
		"the restart did not find the send absent and send it at its base"
	);
}

#[test]
fn a_bot_killed_after_the_commit_before_keeping_keeps_it_after_restart() {
	let rig = killed_at("after-commit", "bot-after-commit");
	let op = rig.sent()[0]["operation"].as_str().unwrap().to_owned();
	assert_eq!(calls_of(&rig, &op), [call("send", 0), call("keep", 0)]);
	assert_eq!(rig.receipts()[0]["kept"], true);
}

#[test]
fn other_commands_between_the_kill_and_the_restart_never_repeat_the_line() {
	let rig = Rig::new("bot-crowded");
	let mut bot = rig.serve(json!({}), Some("after-send"));
	rig.direct(1, "c1", "reply:exactly once");
	assert!(!bot.process.wait().success());
	rig.crowd(12);
	let bot = rig.serve(json!({}), None);
	rig.wait_for_cursor(1);
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(rig.sent().len(), 1, "{:?}", rig.sent());
	assert!(
		!rig.log().contains(words::COULD_NOT_ANSWER),
		"a false failure line was written"
	);
	let op = rig.sent()[0]["operation"].as_str().unwrap().to_owned();
	assert_eq!(
		calls_of(&rig, &op),
		[call("send", 0), call("observe", 0), call("keep", 0)],
		"the unkept line's receipt was held through the other commands"
	);
}

#[test]
fn a_posted_line_whose_receipt_reads_unknown_is_decided_by_its_echo_and_posts_once() {
	// No work will settle the send's receipt. It holds its place through the
	// other commands, as a paused executor's does, and reads unknown.
	let rig = Rig::new("bot-receipt-unknown");
	rig.send_faults(&["unknown"]);
	let mut bot = rig.serve(json!({}), Some("after-send"));
	rig.direct(1, "c1", "reply:posted once");
	assert!(!bot.process.wait().success(), "the bot was not killed after its send");
	rig.crowd(12);
	assert!(
		rig.receipts().iter().any(|receipt| receipt["status"] == "unknown"),
		"the unknown receipt lost its place: {:?}",
		rig.receipts()
	);
	let bot = rig.serve(json!({}), None);
	rig.wait_for_cursor(1);
	// This send's receipt says nothing and activity holds no echo, so the
	// line is given up on rather than guessed at.
	rig.send_faults(&["vanished"]);
	rig.direct(2, "c2", "reply:never posted");
	rig.wait_for_cursor(2);
	let status = rig.status();
	assert!(bot.stop().success(), "the bot exited with a failure");
	let sent = rig.sent();
	assert_eq!(sent.len(), 1, "a line was posted twice or a guess was posted: {sent:?}");
	assert_eq!(sent[0]["text"], "posted once");
	assert_eq!(status["status"]["unconfirmed"], 1, "{}", rig.log());
	let sends = rig.operations("send");
	assert_eq!(sends.len(), 2, "a line was sent again: {sends:?}");
	let op = sent[0]["operation"].as_str().unwrap().to_owned();
	// The session refuses to keep an unknown receipt and takes it back when
	// released, so no receipt is counted as left.
	assert_eq!(
		calls_of(&rig, &op),
		[call("send", 0), call("observe", 0), call("keep", 0), call("release", 0)],
		"the posted line was not found by its echo"
	);
	assert_eq!(status["status"]["unreleased_lines"], 0);
	assert!(!rig.log().contains(words::RECEIPT_LEFT), "{}", rig.log());
	assert!(
		rig.receipts()
			.iter()
			.all(|receipt| receipt["status"] != "unknown" || receipt["released"] == true),
		"an unsettled receipt was left behind: {:?}",
		rig.receipts()
	);
}

#[test]
fn a_bot_killed_after_releasing_a_line_it_gave_up_on_never_sends_it_again() {
	// The line posted, but activity cannot say so across the restart, so the
	// bot gives up on it. The release is recorded as owed before it runs, so
	// the restart finishes it and never reads the gone receipt as unsent.
	let rig = Rig::new("bot-after-release");
	rig.restart_echoes();
	rig.send_faults(&["unknown"]);
	let mut bot = rig.serve(json!({}), Some("after-release"));
	rig.direct(1, "c1", "reply:posted once");
	assert!(
		!bot.process.wait().success(),
		"the bot was not killed after the release"
	);
	assert!(
		rig.receipts().iter().all(|receipt| receipt["released"] == true),
		"the receipt was not released: {:?}",
		rig.receipts()
	);
	let bot = rig.serve(json!({}), None);
	rig.wait_for_cursor(1);
	let status = rig.status();
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(rig.texts(), ["posted once"]);
	let op = rig.sent()[0]["operation"].as_str().unwrap().to_owned();
	assert_eq!(
		calls_of(&rig, &op),
		[call("send", 0), call("release", 0), call("release", 0)]
	);
	assert_eq!(
		status["status"]["unconfirmed"], 0,
		"the restart gave up on the line again"
	);
	let log = rig.log();
	assert_eq!(log.matches(words::CANNOT_SAY_WHETHER).count(), 1, "{log}");
	assert!(!log.contains(words::COULD_NOT_ANSWER), "{log}");
}

#[test]
fn a_posted_line_whose_receipt_is_gone_across_a_session_restart_is_never_sent_again() {
	let rig = Rig::new("bot-restart-evicted");
	rig.send_faults(&["unknown"]);
	let mut bot = rig.serve(json!({}), Some("after-send"));
	rig.direct(1, "c1", "reply:posted once");
	assert!(!bot.process.wait().success(), "the bot was not killed after its send");
	rig.crowd(12);
	rig.restart_echoes();
	let bot = rig.serve(json!({}), None);
	rig.wait_for_cursor(1);
	let status = rig.status();
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(rig.texts(), ["posted once"]);
	let op = rig.sent()[0]["operation"].as_str().unwrap().to_owned();
	assert_eq!(
		calls_of(&rig, &op),
		[call("send", 0), call("observe", 0), call("release", 0)]
	);
	assert_eq!(status["status"]["unconfirmed"], 1);
}

#[test]
fn a_bot_killed_after_recording_the_send_does_not_send_again() {
	let rig = killed_at("after-record", "bot-after-record");
	assert_eq!(
		rig.operations("send").len(),
		1,
		"the restart sent a recorded line again"
	);
}
