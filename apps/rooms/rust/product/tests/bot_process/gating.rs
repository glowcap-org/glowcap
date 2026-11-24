//! What starts or shapes a turn, against the stand-in session. The access the
//! session reports, `/reset`, and the hourly limit decide whether a turn
//! starts. The operator's instructions, the action bound, and the agent's
//! commands outside a turn shape it.
use super::rig::{Rig, eventually, gone, recorded_pid, runs};
use super::words;
use serde_json::json;
use std::time::Duration;

#[test]
fn a_turn_thinking_when_access_stops_is_ended_and_runs_again_once_access_returns() {
	let rig = Rig::new("bot-halt");
	let bot = rig.serve(json!({}), None);
	rig.direct(1, "c1", "wait-file:after the pause");
	let workdir = rig.workdir("c1");
	let first = eventually("the agent to start", || {
		workdir
			.join("harness.pid")
			.exists()
			.then(|| recorded_pid(&workdir, "harness.pid"))
	});
	rig.events_fault(Some("paused"));
	eventually("the agent to be ended", || gone(first).then_some(()));
	eventually("the turn to be halted", || {
		rig.log().contains(words::HALTED).then_some(())
	});
	assert!(rig.sent().is_empty());
	std::fs::write(workdir.join("release"), "").unwrap();
	rig.events_fault(None);
	rig.wait_for_replies(1);
	rig.wait_for_cursor(1);
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(rig.texts(), ["after the pause"]);
	assert_eq!(runs(&workdir), 2);
	assert_eq!(rig.status()["status"]["turns_finished"], 1);
}

/// A halt whose cut-off cannot be written still ends the turn's thinking. The
/// agent does not start again while the access is paused, and a run cut off
/// spends no try, so two such halts, past the bound of two tries, still end
/// in the agent's answer.
#[test]
fn a_halt_whose_cut_off_write_fails_waits_for_the_access_and_spends_no_try() {
	let rig = Rig::new("bot-halt-unsaved");
	let bot = rig.serve(json!({}), Some("cut-off-write@*"));
	rig.direct(1, "c1", "wait-file:after the pause");
	let workdir = rig.workdir("c1");
	let mut ended = None;
	for halt in 1..=2 {
		let pid = eventually("the agent to start", || {
			let pid = workdir
				.join("harness.pid")
				.exists()
				.then(|| recorded_pid(&workdir, "harness.pid"))?;
			(Some(pid) != ended).then_some(pid)
		});
		rig.events_fault(Some("paused"));
		eventually("the agent to be ended", || gone(pid).then_some(()));
		eventually("the turn to be halted", || {
			(rig.log().matches(words::HALTED).count() == halt).then_some(())
		});
		assert_eq!(runs(&workdir), halt, "the agent started while the access was paused");
		ended = Some(pid);
		if halt == 1 {
			// Time passes in the halt, so a deadline the halt kept would
			// show as less than a whole one when the agent starts again. The
			// wait makes that visible and decides nothing else.
			std::thread::sleep(Duration::from_millis(1500));
			rig.events_fault(None);
		}
	}
	assert_eq!(rig.log().matches("os error 5").count(), 2, "{}", rig.log());
	assert!(rig.sent().is_empty());
	std::fs::write(workdir.join("release"), "").unwrap();
	rig.events_fault(None);
	rig.wait_for_replies(1);
	rig.wait_for_cursor(1);
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(rig.texts(), ["after the pause"]);
	assert_eq!(runs(&workdir), 3);
	// A halt gives the run after it a whole deadline, even when the halt
	// could not record its cut-off, so no run started with time taken by
	// the halts before it.
	let left: Vec<u64> = rig
		.log()
		.lines()
		.filter_map(|line| {
			line.split("the agent starts with ")
				.nth(1)?
				.split(' ')
				.next()?
				.parse()
				.ok()
		})
		.collect();
	assert_eq!(left.len(), 3, "{left:?}");
	for ms in &left {
		assert!(*ms > 598_000, "a run started with a deadline a halt had used: {left:?}");
	}
}

/// A give-up whose reply write fails, and a halt that ends the retry's wait,
/// still records why the turn was given up once the reply is saved after the
/// resume: `status` names the failure, and `ready` fails for a sign-in
/// refusal. The write fails once, so the halt must come inside the wait that
/// follows it; a halt that came after the retry would leave the record as it
/// was.
#[test]
fn a_give_up_whose_save_a_halt_interrupted_is_recorded_after_the_resume() {
	let rig = Rig::new("bot-give-up-halt");
	let bot = rig.serve(json!({}), Some("answer-write"));
	rig.direct(1, "c1", "fail:auth token expired");
	eventually("the reply's write to fail", || {
		rig.log().contains("os error 5").then_some(())
	});
	rig.events_fault(Some("paused"));
	eventually("the turn to be halted", || {
		rig.log().contains(words::HALTED).then_some(())
	});
	rig.events_fault(None);
	rig.wait_for_replies(1);
	rig.wait_for_cursor(1);
	let problem = rig.status()["status"]["unanswered"].clone();
	assert_eq!(problem["kind"], "sign-in", "{problem}");
	let log = rig.log();
	assert!(log.contains("gave up"), "{log}");
	let (refused, ok) = rig.run("ready", json!({}));
	assert!(!ok && refused["error"]["class"] == "not-ready", "{refused}");
	assert!(bot.stop().success(), "the bot exited with a failure");
}

/// A run the bot's own stop cuts off is not a try, so a turn stopped more
/// times than the bound of two tries still runs again and ends in the
/// agent's answer. Only a run a kill ends is counted.
#[test]
fn a_run_the_bots_own_stop_cuts_off_is_no_try() {
	let rig = Rig::new("bot-stop-cut-off");
	let workdir = rig.workdir("c1");
	let mut bot = rig.serve(json!({}), None);
	rig.direct(1, "c1", "wait-file:after the stops");
	for stopped in 1..=3 {
		eventually("the agent to start", || (runs(&workdir) == stopped).then_some(()));
		assert!(bot.stop().success(), "the bot exited with a failure");
		bot = rig.serve(json!({}), None);
	}
	eventually("the agent to start a fourth time", || {
		(runs(&workdir) == 4).then_some(())
	});
	std::fs::write(workdir.join("release"), "").unwrap();
	rig.wait_for_replies(1);
	rig.wait_for_cursor(1);
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(rig.texts(), ["after the stops"]);
}

#[test]
fn a_send_that_finds_the_access_paused_ends_the_turns_thinking() {
	let rig = Rig::new("bot-halt-send");
	let bot = rig.serve(json!({}), None);
	rig.direct(1, "c1", "wait-file:after the pause");
	let workdir = rig.workdir("c1");
	let first = eventually("the agent to start", || {
		workdir
			.join("harness.pid")
			.exists()
			.then(|| recorded_pid(&workdir, "harness.pid"))
	});
	// Only the other conversation's send finds the pause, and the stand-in then
	// fails reads as paused until the test resumes the access.
	rig.send_faults(&["paused"]);
	rig.direct(2, "c2", "reply:sent after the pause");
	eventually("the agent to be ended", || gone(first).then_some(()));
	eventually("the turn to be halted", || {
		rig.log().contains(words::HALTED).then_some(())
	});
	rig.events_fault(None);
	std::fs::write(workdir.join("release"), "").unwrap();
	rig.wait_for_replies(2);
	rig.wait_for_cursor(2);
	assert!(bot.stop().success(), "the bot exited with a failure");
	let mut answered = rig.texts();
	answered.sort();
	assert_eq!(answered, ["after the pause", "sent after the pause"]);
	assert_eq!(runs(&workdir), 2);
}

#[test]
fn reset_starts_a_new_agent_conversation_and_says_so() {
	let rig = Rig::new("bot-reset");
	let bot = rig.serve(json!({}), None);
	rig.direct(1, "c1", "reply:first");
	rig.wait_for_cursor(1);
	let sessions = || -> serde_json::Value {
		serde_json::from_slice(&std::fs::read(rig.dir.join("sessions.json")).unwrap()).unwrap()
	};
	assert!(sessions()["fake"]["c1"].is_string());
	rig.direct(2, "c1", "/reset");
	rig.wait_for_cursor(2);
	assert!(sessions()["fake"]["c1"].is_null(), "{}", sessions());
	rig.direct(3, "c1", "reply:after");
	rig.wait_for_cursor(3);
	assert!(bot.stop().success(), "the bot exited with a failure");
	let settings = std::fs::read_to_string(rig.workdir("c1").join("settings.txt")).unwrap();
	assert!(
		!settings.contains("--resume"),
		"the turn after a reset resumed: {settings}"
	);
	let sent = rig.texts();
	assert_eq!(sent.len(), 3);
	assert!(sent[1].starts_with(words::RESET_CONFIRMED), "{sent:?}");
	assert_eq!(runs(&rig.workdir("c1")), 2, "the reset ran the agent");
}

/// A conversation past `--conversation-limit` gets no reply and no turn for
/// the lines past it, which are kept as context. Another conversation is
/// unaffected.
#[test]
fn a_conversation_past_its_hourly_limit_gets_no_reply_and_another_is_unaffected() {
	let rig = Rig::new("bot-conversation-limit");
	let bot = rig.serve(json!({"conversation-limit": ["1"]}), None);
	rig.direct(1, "c1", "reply:within the limit");
	rig.direct(2, "c1", "reply:past the limit");
	rig.direct(3, "c2", "reply:another conversation");
	rig.wait_for_cursor(3);
	assert!(bot.stop().success(), "the bot exited with a failure");
	let mut sent = rig.texts();
	sent.sort();
	assert_eq!(sent, ["another conversation", "within the limit"]);
	assert!(rig.log().contains(&words::context_only("c1")), "{}", rig.log());
}

#[test]
fn the_operators_instructions_are_read_for_every_turn() {
	let rig = Rig::new("bot-instructions");
	let file = rig.dir.with_file_name("instructions.md");
	std::fs::write(&file, "Answer in French.").unwrap();
	let bot = rig.serve(json!({"instructions": [file]}), None);
	rig.direct(1, "c1", "reply:one");
	rig.wait_for_cursor(1);
	let settings = || std::fs::read_to_string(rig.workdir("c1").join("settings.txt")).unwrap();
	assert!(settings().contains("Answer in French."), "{}", settings());
	std::fs::write(&file, "Answer in Dutch.").unwrap();
	rig.direct(2, "c1", "reply:two");
	rig.wait_for_cursor(2);
	assert!(settings().contains("Answer in Dutch."), "{}", settings());
	std::fs::remove_file(&file).unwrap();
	rig.direct(3, "c1", "reply:three");
	rig.wait_for_cursor(3);
	assert!(bot.stop().success(), "the bot exited with a failure");
	let sent = rig.texts();
	assert!(sent[2].contains(words::INSTRUCTIONS_UNREADABLE), "{sent:?}");
}

#[test]
fn serve_no_instructions_drops_the_stored_instructions_file() {
	let rig = Rig::new("bot-no-instructions");
	let file = rig.dir.with_file_name("instructions.md");
	std::fs::write(&file, "Answer in French.").unwrap();
	let bot = rig.serve(json!({"instructions": [file]}), None);
	rig.direct(1, "c1", "reply:one");
	rig.wait_for_cursor(1);
	let settings =
		|conversation: &str| std::fs::read_to_string(rig.workdir(conversation).join("settings.txt")).unwrap();
	assert!(settings("c1").contains("Answer in French."), "{}", settings("c1"));
	assert!(bot.stop().success(), "the bot exited with a failure");
	let bot = rig.serve(json!({"no-instructions": ["true"]}), None);
	rig.direct(2, "c2", "reply:two");
	rig.wait_for_cursor(2);
	assert!(!settings("c2").contains("Answer in French."), "{}", settings("c2"));
	assert!(bot.stop().success(), "the bot exited with a failure");
	// The choice is stored: a start that names nothing keeps it.
	let bot = rig.serve(json!({}), None);
	rig.direct(3, "c3", "reply:three");
	rig.wait_for_cursor(3);
	assert!(!settings("c3").contains("Answer in French."), "{}", settings("c3"));
	assert!(bot.stop().success(), "the bot exited with a failure");
}

/// The bound holds however the agent is prompted, and the refusal names it.
/// The stand-in holds no session link, so each verb that takes a place then
/// fails to attach, which is enough to count places.
#[test]
fn a_turn_acts_at_most_a_fixed_number_of_times_and_shows_typing_while_it_thinks() {
	let rig = Rig::new("bot-actions");
	let bot = rig.serve(json!({}), None);
	let say = json!({"verb": "say", "state": "", "named": {"text": ["again"]}, "arguments": []});
	let requests = vec![say; 13];
	rig.direct(1, "c1", &format!("act:{}", serde_json::Value::from(requests)));
	rig.wait_for_cursor(1);
	assert!(bot.stop().success(), "the bot exited with a failure");
	let refused: serde_json::Value =
		serde_json::from_slice(&std::fs::read(rig.workdir("c1").join("act-12.out")).unwrap()).unwrap();
	let message = refused["error"]["message"].as_str().unwrap_or_default();
	assert!(message.contains("at most 12 times"), "{refused}");
	// The agent reads a verb's standard error too, so the harness saves it
	// for the link scan.
	let error = std::fs::read_to_string(rig.workdir("c1").join("act-12.err")).unwrap();
	assert!(error.contains("at most 12 times"), "{error}");
	let attached: serde_json::Value =
		serde_json::from_slice(&std::fs::read(rig.workdir("c1").join("act-11.out")).unwrap()).unwrap();
	assert!(
		attached["error"]["message"]
			.as_str()
			.unwrap_or_default()
			.contains(words::NO_SESSION_LINK),
		"the last place was refused too: {attached}"
	);
	// The bot showed itself typing while the agent ran, and stopped once the
	// turn stopped thinking.
	let typing = std::fs::read_to_string(rig.rooms.join("typing.jsonl")).unwrap_or_default();
	let levels: Vec<serde_json::Value> = typing.lines().map(|row| serde_json::from_str(row).unwrap()).collect();
	assert_eq!(
		levels.first(),
		Some(&json!({"conversation": "c1", "on": true})),
		"{typing}"
	);
	assert_eq!(
		levels.last(),
		Some(&json!({"conversation": "c1", "on": false})),
		"{typing}"
	);
	// The turn is over, so its budget is closed.
	let (refused, ok) = rig.run_turn("c1", "say", json!({"text": ["late"]}), &[]);
	assert!(!ok, "{refused}");
	assert!(
		refused["error"]["message"]
			.as_str()
			.unwrap_or_default()
			.contains(words::ONLY_WHILE_TURN),
		"{refused}"
	);
}

#[test]
fn the_agents_commands_run_only_inside_a_turn() {
	let rig = Rig::new("bot-outside");
	let (refused, ok) = rig.run_turn("", "say", json!({"text": ["hi"]}), &[]);
	assert!(!ok && refused["error"]["class"] == "invalid", "{refused}");
	assert!(
		refused["error"]["message"]
			.as_str()
			.unwrap()
			.contains("GLOWCAP_ROOMS_TURN_CONVERSATION"),
		"{refused}"
	);
	let (refused, ok) = rig.run("say", json!({"text": ["hi"]}));
	assert!(!ok && refused["error"]["class"] == "invalid", "{refused}");
}
