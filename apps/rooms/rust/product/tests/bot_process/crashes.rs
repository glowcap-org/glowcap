//! A harness that fails, and a bot that stops or dies at each step of a turn.
use super::rig::{Rig, eventually, gone, recorded_pid};
use serde_json::json;
use std::path::Path;

/// How many times the fake harness started in a conversation's directory.
fn runs(workdir: &Path) -> usize {
	std::fs::read_to_string(workdir.join("runs.log")).map_or(0, |log| log.lines().count())
}

/// The session each run of the fake harness was asked to resume, `-` for none.
fn resumes(workdir: &Path) -> Vec<String> {
	std::fs::read_to_string(workdir.join("runs.log"))
		.unwrap_or_default()
		.lines()
		.filter_map(|line| line.rsplit_once("resume=").map(|(_, id)| id.to_owned()))
		.collect()
}

#[test]
fn a_crashing_harness_is_retried_then_reported_once_and_the_bot_carries_on() {
	let rig = Rig::new("bot-crash");
	let bot = rig.serve(json!({}), None);
	rig.direct(1, "c1", "crash-once");
	let sent = rig.wait_for_replies(1);
	assert_eq!(sent[0]["text"], "recovered", "the second run should have answered");
	rig.wait_for_cursor(1);

	rig.direct(2, "c2", "crash");
	let sent = rig.wait_for_replies(2);
	assert_eq!(
		sent[1]["text"],
		"I could not answer that: the agent stopped unexpectedly, after 2 tries."
	);
	rig.wait_for_cursor(2);

	rig.direct(3, "c2", "reply:fine now");
	assert_eq!(rig.wait_for_replies(3)[2]["text"], "fine now");
	rig.wait_for_cursor(3);
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(rig.sent().len(), 3, "a trigger was answered more than once");
	assert_eq!(runs(&rig.workdir("c1")), 2, "crash-once should run twice");
	// The agent named its session before it crashed, so the second try resumes
	// that session and the next turn resumes it again. The failed turn starts
	// the agent twice, the number its failure line says.
	let c2 = resumes(&rig.workdir("c2"));
	assert_eq!(c2.len(), 3, "a crashed turn or the one after it ran too often: {c2:?}");
	assert_eq!(c2[0], "-");
	assert!(c2[1] != "-" && c2[1] == c2[2], "a crash dropped the session: {c2:?}");
}

#[test]
fn an_agent_that_never_finds_the_session_starts_a_new_one_within_the_turns_tries() {
	let rig = Rig::new("bot-lost-session");
	let bot = rig.serve(json!({}), None);
	rig.direct(1, "c1", "reply:first");
	rig.wait_for_replies(1);
	rig.wait_for_cursor(1);
	rig.direct(2, "c1", "reject-resume:second");
	assert_eq!(rig.wait_for_replies(2)[1]["text"], "second");
	rig.wait_for_cursor(2);
	rig.direct(3, "c2", "reply:one");
	rig.wait_for_replies(3);
	rig.wait_for_cursor(3);
	rig.direct(4, "c2", "reject-resume-crash");
	let sent = rig.wait_for_replies(4);
	assert_eq!(
		sent[3]["text"],
		"I could not answer that: the agent stopped unexpectedly, after 2 tries."
	);
	rig.wait_for_cursor(4);
	assert!(bot.stop().success(), "the bot exited with a failure");
	let c1 = resumes(&rig.workdir("c1"));
	assert_eq!(c1.len(), 3, "{c1:?}");
	assert!(
		c1[1] != "-" && c1[2] == "-",
		"the new session was not started fresh: {c1:?}"
	);
	assert_eq!(
		resumes(&rig.workdir("c2")).len(),
		3,
		"the failed turn started the agent too often"
	);
}

#[test]
fn a_failure_line_carries_the_agents_cleaned_message() {
	let rig = Rig::new("bot-failure-cause");
	let bot = rig.serve(json!({}), None);
	rig.direct(1, "c1", "fail:rate 429: slow down, see /home/ann/.bot/session.link now");
	let sent = rig.wait_for_replies(1);
	rig.wait_for_cursor(1);
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(
		sent[0]["text"],
		"I could not answer that: the agent hit a usage limit: 429: slow down, see [hidden] now."
	);
}

#[test]
fn a_harness_answer_survives_its_own_nonzero_exit() {
	let rig = Rig::new("bot-exit-after-reply");
	let bot = rig.serve(json!({}), None);
	rig.direct(1, "c1", "exit-after-reply:answered then died");
	assert_eq!(rig.wait_for_replies(1)[0]["text"], "answered then died");
	rig.wait_for_cursor(1);
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(rig.sent().len(), 1, "a trigger was answered more than once");
	assert_eq!(runs(&rig.workdir("c1")), 1, "an answered turn ran the harness again");
}

#[test]
fn a_failed_write_of_the_answer_is_retried_without_running_the_harness_again() {
	let rig = Rig::new("bot-answer-write");
	let bot = rig.serve(json!({}), Some("answer-write"));
	rig.direct(1, "c1", "reply:written on the second try");
	assert_eq!(rig.wait_for_replies(1)[0]["text"], "written on the second try");
	rig.wait_for_cursor(1);
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(rig.sent().len(), 1, "the reply was posted more than once");
	assert_eq!(
		runs(&rig.workdir("c1")),
		1,
		"a failed ledger write ran the harness again"
	);
	assert!(rig.log().contains("trying again without running it"), "{}", rig.log());
}

#[test]
fn a_hung_harness_is_killed_with_everything_it_started() {
	let rig = Rig::new("bot-hang");
	let bot = rig.serve(json!({"deadline": ["2"]}), None);
	rig.direct(1, "c1", "hang");
	let sent = rig.wait_for_replies(1);
	assert_eq!(
		sent[0]["text"],
		"I could not answer that: the agent did not finish within 2 seconds."
	);
	rig.wait_for_cursor(1);
	let workdir = rig.workdir("c1");
	assert!(
		gone(recorded_pid(&workdir, "harness.pid")),
		"the harness outlived its deadline"
	);
	assert!(
		gone(recorded_pid(&workdir, "child.pid")),
		"the harness's child outlived its deadline"
	);
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(rig.sent().len(), 1, "a trigger was answered more than once");
}

#[test]
fn a_bot_killed_while_the_harness_runs_finishes_the_turn_after_restart() {
	let rig = Rig::new("bot-killed-running");
	let mut bot = rig.serve(json!({}), None);
	rig.direct(1, "c1", "slow-once:done at last");
	let workdir = rig.workdir("c1");
	let orphan = recorded_pid(&workdir, "harness.pid");
	eventually("the harness to start its slow turn", || {
		workdir.join("slow.marker").exists().then_some(())
	});
	bot.kill();
	assert!(rig.sent().is_empty());

	let bot = rig.serve(json!({}), None);
	assert_eq!(rig.wait_for_replies(1)[0]["text"], "done at last");
	rig.wait_for_cursor(1);
	assert!(gone(orphan), "the harness the dead bot left behind was not ended");
	assert!(rig.log().contains("ended harness group"), "{}", rig.log());
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(rig.sent().len(), 1, "a trigger was answered more than once");
}

#[test]
fn sigterm_during_a_turn_ends_the_harness_and_the_restart_answers_once() {
	let rig = Rig::new("bot-sigterm");
	let bot = rig.serve(json!({}), None);
	rig.direct(1, "c1", "wait-file:after the stop");
	let workdir = rig.workdir("c1");
	let harness = recorded_pid(&workdir, "harness.pid");
	eventually("the turn to start", || {
		workdir.join("waiting.marker").exists().then_some(())
	});
	assert!(bot.stop().success(), "a stopped bot exited with a failure");
	assert!(gone(harness), "the harness outlived the stopped bot");
	let row = &rig.ledger()["turns"][0];
	assert_eq!(
		(row["phase"].as_str(), row["progress"].as_str()),
		(Some("running"), Some("cutoff")),
		"{row}"
	);
	assert_eq!(row["spent"], 0, "the bot's own stop spent a run");
	assert!(rig.sent().is_empty());

	std::fs::write(workdir.join("release"), "").unwrap();
	let bot = rig.serve(json!({}), None);
	assert_eq!(rig.wait_for_replies(1)[0]["text"], "after the stop");
	rig.wait_for_cursor(1);
	let prompt = std::fs::read_to_string(workdir.join("prompt.txt")).unwrap();
	assert!(
		prompt.starts_with("An earlier run of this turn was cut off"),
		"{prompt}"
	);
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(rig.sent().len(), 1, "a trigger was answered more than once");
}

#[test]
fn turns_that_finish_out_of_order_are_each_answered_once_across_a_restart() {
	let rig = Rig::new("bot-out-of-order");
	let mut bot = rig.serve(json!({}), None);
	rig.direct(1, "c1", "wait-file:slow one");
	let slow = rig.workdir("c1");
	eventually("the slow turn to start", || {
		slow.join("waiting.marker").exists().then_some(())
	});
	// A turn of its own that waits behind the slow one. The ledger holds it,
	// so the cursor moves past it.
	rig.direct(2, "c1", "reply:queued behind");
	rig.direct(3, "c2", "reply:quick one");
	assert_eq!(rig.wait_for_replies(1)[0]["text"], "quick one");
	eventually("the quick turn to finish", || {
		let status = rig.status()["status"].clone();
		(status["turns_finished"] == 1 && status["open_turns"] == 2 && status["queued"] == 0).then_some(())
	});
	let cursor = rig.status()["status"]["cursor"].as_str().map(str::to_owned);
	let reached = cursor
		.as_deref()
		.and_then(|cursor| cursor.strip_prefix('e'))
		.and_then(|hex| u64::from_str_radix(hex, 16).ok());
	assert_eq!(reached, Some(3), "the cursor stayed before a trigger a turn holds");
	bot.kill();

	std::fs::write(slow.join("release"), "").unwrap();
	let bot = rig.serve(json!({}), None);
	rig.wait_for_replies(3);
	rig.wait_for_cursor(3);
	assert!(bot.stop().success(), "the bot exited with a failure");
	let mut texts: Vec<_> = rig
		.sent()
		.iter()
		.map(|line| line["text"].as_str().unwrap().to_owned())
		.collect();
	texts.sort();
	assert_eq!(
		texts,
		["queued behind", "quick one", "slow one"],
		"a trigger was lost or answered twice"
	);
}

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
		!rig.log().contains("I could not answer that"),
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
fn a_posted_line_whose_receipt_was_let_go_is_decided_by_its_echo_and_posts_once() {
	// No work will settle the send's receipt, so the session lets it go
	// under the other commands, and the restart finds no receipt.
	let rig = Rig::new("bot-receipt-evicted");
	rig.send_faults(&["unknown"]);
	let mut bot = rig.serve(json!({}), Some("after-send"));
	rig.direct(1, "c1", "reply:posted once");
	assert!(!bot.process.wait().success(), "the bot was not killed after its send");
	rig.crowd(12);
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
	assert_eq!(
		calls_of(&rig, &op),
		[call("send", 0), call("observe", 0), call("keep", 0)],
		"the posted line was not found by its echo"
	);
	assert!(
		rig.receipts().iter().all(|receipt| receipt["status"] != "unknown"),
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
		rig.receipts().is_empty(),
		"the receipt was not released: {:?}",
		rig.receipts()
	);
	let bot = rig.serve(json!({}), None);
	rig.wait_for_cursor(1);
	let status = rig.status();
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(texts_of(&rig), ["posted once"]);
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
	assert_eq!(log.matches("cannot say whether operation").count(), 1, "{log}");
	assert!(!log.contains("I could not answer that"), "{log}");
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
	assert_eq!(texts_of(&rig), ["posted once"]);
	let op = rig.sent()[0]["operation"].as_str().unwrap().to_owned();
	assert_eq!(
		calls_of(&rig, &op),
		[call("send", 0), call("observe", 0), call("release", 0)]
	);
	assert_eq!(status["status"]["unconfirmed"], 1);
}

fn texts_of(rig: &Rig) -> Vec<String> {
	rig.sent()
		.iter()
		.map(|line| line["text"].as_str().unwrap_or_default().to_owned())
		.collect()
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
