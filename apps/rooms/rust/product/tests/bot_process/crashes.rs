//! Agent failures, and stops during a turn.
use super::rig::{Rig, eventually, gone, recorded_pid, runs};
use super::words;
use serde_json::json;
use std::path::Path;

/// The session each run of the fake harness was asked to resume, `-` for none.
fn resumes(workdir: &Path) -> Vec<String> {
	std::fs::read_to_string(workdir.join("runs.log"))
		.unwrap_or_default()
		.lines()
		.filter_map(|line| line.rsplit_once("resume=").map(|(_, id)| id.to_owned()))
		.collect()
}

/// The milliseconds of the reply's deadline each start of the agent had
/// left, in the order the bot logged them.
fn deadline_left(log: &str) -> Vec<u64> {
	log.lines()
		.filter_map(|line| {
			line.split_once("the agent starts with ")?
				.1
				.split(' ')
				.next()?
				.parse()
				.ok()
		})
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
		format!(
			"{}: the agent stopped unexpectedly, after 2 tries.",
			words::COULD_NOT_ANSWER
		)
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
		format!(
			"{}: the agent stopped unexpectedly, after 2 tries.",
			words::COULD_NOT_ANSWER
		)
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
fn a_failure_line_never_carries_the_agents_words_and_the_log_does() {
	let rig = Rig::new("bot-failure-cause");
	let bot = rig.serve(json!({}), None);
	rig.direct(1, "c1", "fail:rate 429: slow down, see /home/ann/.bot/session.link now");
	let sent = rig.wait_for_replies(1);
	rig.wait_for_cursor(1);
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(
		sent[0]["text"],
		format!("{}: the agent hit a usage limit.", words::COULD_NOT_ANSWER)
	);
	assert!(rig.log().contains("429: slow down"), "{}", rig.log());
	let unanswered = rig.status()["status"]["unanswered"]["message"].clone();
	assert!(!unanswered.as_str().unwrap().contains("slow down"), "{unanswered}");
}

/// A turn the agent could not answer shows in `status` with its kind until a
/// later turn is answered. A sign-in refusal also fails `ready`, and its
/// message reaches the operator and never the room.
#[test]
fn an_unanswered_turn_shows_in_status_until_the_next_answer_and_a_sign_in_refusal_fails_ready() {
	let rig = Rig::new("bot-gave-up");
	let bot = rig.serve(json!({}), None);
	rig.direct(1, "c1", "fail:auth token sk-secret expired");
	let sent = rig.wait_for_replies(1);
	rig.wait_for_cursor(1);
	let text = sent[0]["text"].as_str().unwrap();
	assert!(text.contains("sign-in") && !text.contains("sk-secret"), "{text}");
	let problem = rig.status()["status"]["unanswered"].clone();
	assert_eq!(problem["kind"], "sign-in", "{problem}");
	assert!(!problem["message"].as_str().unwrap().contains("sk-secret"), "{problem}");
	// The agent's own words reach no log either, only the failure's label.
	let log = rig.log();
	assert!(log.contains("the agent refused its sign-in"), "{log}");
	assert!(!log.contains("sk-secret"), "the log holds a sign-in refusal's words");
	assert!(rig.status()["status"]["last_error"].is_null(), "{}", rig.status());
	let (refused, ok) = rig.run("ready", json!({}));
	assert!(!ok && refused["error"]["class"] == "not-ready", "{refused}");
	assert!(
		refused["error"]["message"].as_str().unwrap().contains("sign-in"),
		"{refused}"
	);
	rig.direct(2, "c1", "reply:answered");
	rig.wait_for_replies(2);
	rig.wait_for_cursor(2);
	assert!(rig.status()["status"]["unanswered"].is_null(), "{}", rig.status());
	assert!(rig.run("ready", json!({})).1);
	assert!(bot.stop().success(), "the bot exited with a failure");
}

#[test]
fn an_endpoint_outage_is_retried_and_reported_as_an_outage() {
	let rig = Rig::new("bot-outage");
	let bot = rig.serve(json!({}), None);
	rig.direct(1, "c1", "fail:outage 503 unavailable");
	let sent = rig.wait_for_replies(1);
	rig.wait_for_cursor(1);
	let text = sent[0]["text"].as_str().unwrap();
	assert!(
		text.contains("unavailable") && !text.contains("stopped unexpectedly"),
		"{text}"
	);
	let problem = rig.status()["status"]["unanswered"].clone();
	assert_eq!(problem["kind"], "outage", "{problem}");
	assert_eq!(runs(&rig.workdir("c1")), 2);
	assert!(rig.run("ready", json!({})).1);
	assert!(bot.stop().success(), "the bot exited with a failure");
}

/// The kind of the failure that spent a try is remembered by the ledger, so
/// a bot restarted before the last try still says why it gave up.
#[test]
fn a_restart_between_tries_keeps_the_kind_of_the_failure_that_spent_one() {
	let rig = Rig::new("bot-kind-restart");
	let mut bot = rig.serve(json!({}), None);
	rig.direct(1, "c1", "outage-then-wait:never");
	let workdir = rig.workdir("c1");
	eventually("the second try to start", || {
		workdir.join("waiting.marker").exists().then_some(())
	});
	bot.kill();
	bot.process.wait();
	let bot = rig.serve(json!({}), None);
	let sent = rig.wait_for_replies(1);
	rig.wait_for_cursor(1);
	assert!(sent[0]["text"].as_str().unwrap().contains("unavailable"), "{sent:?}");
	let problem = rig.status()["status"]["unanswered"].clone();
	assert_eq!(problem["kind"], "outage", "{problem}");
	assert!(bot.stop().success(), "the bot exited with a failure");
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
	assert!(rig.log().contains(words::SAVE_RETRIED_WITHOUT_RUNNING), "{}", rig.log());
}

#[test]
fn a_failed_write_of_a_give_up_line_is_retried_without_running_the_harness_again() {
	let rig = Rig::new("bot-give-up-write");
	let bot = rig.serve(json!({}), Some("answer-write"));
	rig.direct(1, "c1", "fail:outage 503 unavailable");
	let sent = rig.wait_for_replies(1);
	rig.wait_for_cursor(1);
	assert!(sent[0]["text"].as_str().unwrap().contains("unavailable"), "{sent:?}");
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(rig.sent().len(), 1, "the failure line was posted more than once");
	assert_eq!(
		runs(&rig.workdir("c1")),
		2,
		"a failed ledger write ran the harness again"
	);
	assert!(rig.log().contains(words::SAVE_RETRIED_WITHOUT_RUNNING), "{}", rig.log());
}

/// A reply whose write fails for good becomes a failure line, and when that
/// write fails too, the turn thinks again after a wait. Each think logs the
/// refusal twice, so a fourth refusal comes from a second think, which writes
/// the failure line again and never runs the harness.
#[test]
fn a_reply_whose_write_fails_for_good_never_runs_the_harness_again() {
	let rig = Rig::new("bot-answer-refused");
	let bot = rig.serve(json!({}), Some("answer-refused@*"));
	rig.direct(1, "c1", "reply:never written");
	eventually("a second think after the writes failed", || {
		(rig.log().matches("os error 13").count() >= 4).then_some(())
	});
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(
		runs(&rig.workdir("c1")),
		1,
		"a reply that could not be written ran the harness again: {}",
		rig.log()
	);
	assert!(rig.sent().is_empty(), "{:?}", rig.texts());
}

#[test]
fn a_hung_harness_is_killed_with_everything_it_started() {
	let rig = Rig::new("bot-hang");
	let bot = rig.serve(json!({"deadline": ["2"]}), None);
	rig.direct(1, "c1", "hang");
	let sent = rig.wait_for_replies(1);
	assert_eq!(
		sent[0]["text"],
		format!(
			"{}: the agent did not finish within 2 seconds.",
			words::COULD_NOT_ANSWER
		)
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
	assert!(rig.log().contains(words::ENDED_GROUP), "{}", rig.log());
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(rig.sent().len(), 1, "a trigger was answered more than once");
}

/// A stop that comes while the restart fetches a turn's files, before any
/// run starts, cuts nothing off. The run the crash left in flight stays in
/// flight, so the next start still counts it and the prompt still says the
/// agent was interrupted.
#[test]
fn a_stop_before_a_run_starts_leaves_the_crashed_run_in_flight() {
	let rig = Rig::new("bot-stop-before-run");
	let mut bot = rig.serve(json!({}), None);
	std::fs::create_dir(rig.rooms.join("files")).unwrap();
	std::fs::write(rig.rooms.join("files").join("t-0"), "x").unwrap();
	rig.push(
		json!({"at": 1, "conversation": "c1", "kind": "direct", "text": "wait-file:after the stop",
		"files": [{"token": "t", "index": 0, "name": "f", "mime": "text/plain", "size": 1, "width": 0, "height": 0}]}),
	);
	let workdir = rig.workdir("c1");
	eventually("the turn to start", || {
		workdir.join("waiting.marker").exists().then_some(())
	});
	bot.kill();
	bot.process.wait();
	std::fs::write(rig.rooms.join("fetch-faults"), "hang\n").unwrap();
	let bot = rig.serve(json!({}), None);
	eventually("the restart to fetch the file", || {
		rig.rooms.join("fetch-faults").exists().then(|| {
			std::fs::read_to_string(rig.rooms.join("fetch-faults"))
				.map(|text| text.trim().is_empty())
				.unwrap_or(false)
				.then_some(())
		})?
	});
	assert!(bot.stop().success(), "the bot exited with a failure");
	let row = &rig.ledger()["turns"][0];
	assert_eq!(
		(row["phase"].as_str(), row["progress"].as_str()),
		(Some("running"), Some("inflight")),
		"{row}"
	);
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
		prompt.starts_with("An earlier run of this turn did not give its answer."),
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

#[test]
fn a_new_session_after_a_silent_resume_gets_only_what_is_left_of_the_reply_deadline() {
	let rig = Rig::new("bot-deadline-shared");
	let bot = rig.serve(json!({"deadline": ["4"]}), None);
	rig.direct(1, "c1", "reply:first");
	rig.wait_for_replies(1);
	rig.wait_for_cursor(1);
	// The resumed run fails silently after 3 of the 4 seconds, and the run on
	// a new session never answers.
	rig.direct(2, "c1", "reject-resume-slow:3");
	let workdir = rig.workdir("c1");
	eventually("the run on a new session to start", || {
		workdir.join("fresh.marker").exists().then_some(())
	});
	let sent = rig.wait_for_replies(2);
	assert_eq!(
		sent[1]["text"],
		format!(
			"{}: the agent did not finish within 4 seconds.",
			words::COULD_NOT_ANSWER
		)
	);
	rig.wait_for_cursor(2);
	assert!(bot.stop().success(), "the bot exited with a failure");
	// The resumed run waited 3 seconds before it failed, so the run on a new
	// session had at most 1 of the 4 left, however slow the host.
	let log = rig.log();
	let left = deadline_left(&log);
	assert_eq!(left.len(), 3, "{log}");
	assert!(
		left[2] <= 1000,
		"the run on a new session had a deadline of its own: {log}"
	);
}

/// A run that ended in a retry whose write fails sends the turn back to think
/// after a wait of one second. The next run has only what is left of the
/// reply's deadline, so at least that second less than the first had.
#[test]
fn a_turn_sent_back_to_think_by_a_failed_write_keeps_its_replys_deadline() {
	let rig = Rig::new("bot-deadline-kept");
	let bot = rig.serve(json!({"deadline": ["60"]}), Some("retry-write@1"));
	rig.direct(1, "c1", "crash-once");
	rig.wait_for_replies(1);
	rig.wait_for_cursor(1);
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(rig.texts(), ["recovered"]);
	let log = rig.log();
	assert!(log.contains("os error 5"), "the retry's write did not fail: {log}");
	let left = deadline_left(&log);
	assert_eq!(left.len(), 2, "{log}");
	assert!(
		left[1] + 1000 <= left[0],
		"the second run had a deadline of its own: {log}"
	);
}
