//! Ordinary turns, what does not trigger one, and what the bot refuses.
use super::rig::{Rig, eventually};
use super::session_rig::LinkSecret;
use super::words;
use serde_json::json;

#[test]
fn a_direct_message_gets_one_reply_and_the_next_turn_resumes_the_harness_session() {
	let rig = Rig::new("bot-dm");
	let bot = rig.serve(json!({}), None);
	rig.direct(1, "c1", "please reply:hello there");
	let sent = rig.wait_for_replies(1);
	assert_eq!(sent[0]["conversation"], "c1");
	assert_eq!(sent[0]["text"], "hello there");
	rig.wait_for_cursor(1);

	let status = rig.status();
	assert_eq!(status["running"], true);
	assert_eq!(status["status"]["harness"], "fake");
	assert_eq!(status["status"]["access"], "active");
	assert_eq!(status["status"]["turns_finished"], 1);

	// The harness ran in its conversation's directory with the system prompt.
	let workdir = rig.workdir("c1");
	let settings = std::fs::read_to_string(workdir.join("settings.txt")).unwrap();
	assert!(
		settings.contains(&format!("{} apps rooms bot workspace", rig.glowcap().display())),
		"{settings}"
	);
	assert!(
		!settings.contains("--dir"),
		"the prompt names a bot directory: {settings}"
	);
	assert!(settings.contains(r#"conversation id "c1""#), "{settings}");
	assert!(settings.contains("--permission safe"));
	assert!(
		!settings.contains("--resume"),
		"a first turn resumed a session: {settings}"
	);
	let prompt = std::fs::read_to_string(workdir.join("prompt.txt")).unwrap();
	assert!(
		prompt.contains(r#"{"line":"l1","text":"please reply:hello there"}"#),
		"{prompt}"
	);
	let sessions: serde_json::Value =
		serde_json::from_slice(&std::fs::read(rig.dir.join("sessions.json")).unwrap()).unwrap();
	let session = sessions["fake"]["c1"].as_str().unwrap().to_owned();
	assert!(session.starts_with("fa4e0000-"), "{sessions}");

	// The second turn hands the harness the session the first one reported.
	rig.direct(2, "c1", "reply:again");
	rig.wait_for_replies(2);
	rig.wait_for_cursor(2);
	let settings = std::fs::read_to_string(workdir.join("settings.txt")).unwrap();
	assert!(settings.contains(&format!("--resume {session}")), "{settings}");
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(rig.sent().len(), 2, "a trigger was answered more than once");
}

/// Whether `text` has the shape `2026-11-21T09:30:05Z`.
fn is_utc_stamp(text: &str) -> bool {
	let shape = "dddd-dd-ddTdd:dd:ddZ";
	text.len() == shape.len()
		&& text.bytes().zip(shape.bytes()).all(|(have, want)| match want {
			b'd' => have.is_ascii_digit(),
			fixed => have == fixed,
		})
}

#[test]
fn the_finished_count_survives_a_restart_and_the_log_times_and_names_each_turn() {
	let rig = Rig::new("bot-finished-count");
	let first = rig.serve(json!({}), None);
	rig.direct(1, "c1", "reply:private words");
	rig.wait_for_replies(1);
	rig.wait_for_cursor(1);
	assert!(first.stop().success(), "the bot exited with a failure");
	let second = rig.serve(json!({}), None);
	rig.direct(2, "c1", "reply:more private words");
	rig.wait_for_replies(2);
	rig.wait_for_cursor(2);
	eventually("the count to include both runs of the bot", || {
		(rig.status()["status"]["turns_finished"] == 2).then_some(())
	});
	assert!(second.stop().success(), "the bot exited with a failure");

	let log = rig.log();
	for line in log.lines() {
		let stamp = line.split_once(' ').map(|(stamp, _)| stamp);
		assert!(stamp.is_some_and(is_utc_stamp), "a log line has no UTC time: {line}");
	}
	assert!(log.contains(&format!(" turn 0 {} c1", words::TURN_STARTED)), "{log}");
	assert!(log.contains(&format!(" turn 1 {} c1", words::TURN_STARTED)), "{log}");
	let finished = log
		.lines()
		.filter(|line| line.contains(&format!("{} c1 after ", words::TURN_FINISHED)) && line.ends_with(": answered"))
		.count();
	assert_eq!(finished, 2, "{log}");
	assert!(!log.contains("private words"), "the log holds message text: {log}");
}

#[test]
fn a_room_line_that_does_not_mention_the_bot_is_remembered_and_never_answered() {
	let rig = Rig::new("bot-room");
	let bot = rig.serve(json!({}), None);
	rig.room(1, "r1", "anyone around for lunch", false);
	rig.wait_for_cursor(1);
	assert!(rig.sent().is_empty(), "an unaddressed line was answered");

	rig.room(2, "r1", "bot, reply:lunch is at noon", true);
	let sent = rig.wait_for_replies(1);
	assert_eq!(sent[0]["text"], "lunch is at noon");
	rig.wait_for_cursor(2);
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(rig.sent().len(), 1, "a trigger was answered more than once");
	let prompt = std::fs::read_to_string(rig.workdir("r1").join("prompt.txt")).unwrap();
	assert!(
		prompt.contains(r#"{"from":"ann","text":"anyone around for lunch"}"#),
		"the context line is missing: {prompt}"
	);
	assert!(
		prompt.contains(r#"{"line":"l2","from":"ann","text":"bot, reply:lunch is at noon"}"#),
		"{prompt}"
	);
}

#[test]
fn triggers_that_arrive_during_a_turn_are_answered_together_by_one_reply() {
	let rig = Rig::new("bot-batch");
	let bot = rig.serve(json!({}), None);
	rig.direct(1, "c1", "wait-file:first");
	let workdir = rig.workdir("c1");
	eventually("the first turn to start", || {
		workdir.join("waiting.marker").exists().then_some(())
	});
	rig.direct(2, "c1", "and another thing");
	rig.direct(3, "c1", "reply:both seen");
	eventually("both lines to be held in one turn behind the first", || {
		let status = rig.status()["status"].clone();
		(status["open_turns"] == 2 && status["queued"] == 0).then_some(())
	});
	std::fs::write(workdir.join("release"), "").unwrap();
	rig.wait_for_replies(2);
	rig.wait_for_cursor(3);
	assert!(bot.stop().success(), "the bot exited with a failure");
	let sent = rig.sent();
	assert_eq!(
		sent.iter()
			.map(|line| line["text"].as_str().unwrap())
			.collect::<Vec<_>>(),
		["first", "both seen"]
	);
	assert_eq!(rig.sent().len(), 2, "the batched lines got a reply each");
	let prompt = std::fs::read_to_string(workdir.join("prompt.txt")).unwrap();
	assert!(
		prompt.contains(r#""line":"l2""#) && prompt.contains(r#""line":"l3""#),
		"{prompt}"
	);
	assert!(!prompt.contains(r#""line":"l1""#), "{prompt}");
}

#[test]
fn a_second_serve_and_an_unusable_configuration_are_refused_by_name() {
	let rig = Rig::new("bot-refusals");
	let bot = rig.serve(json!({}), None);
	let (refused, ok) = rig.run("serve", json!({"rooms-dir": [rig.rooms]}));
	assert!(!ok);
	assert_eq!(refused["error"]["class"], "in-use");
	bot.terminate();

	let (refused, ok) = rig.run("serve", json!({"rooms-dir": [rig.rooms], "deadline": ["0"]}));
	assert!(!ok);
	assert_eq!(refused["error"]["class"], "config");
	let (refused, ok) = rig.run("serve", json!({"rooms-dir": [rig.rooms], "harness": ["nope"]}));
	assert!(!ok && refused["error"]["class"] == "config");
	let (refused, ok) = rig.run("serve", json!({"rooms-dir": [rig.rooms], "bogus": ["x"]}));
	assert!(!ok && refused["error"]["class"] == "invalid");
	let (stopped, ok) = rig.run("status", json!({}));
	assert!(ok && stopped["running"] == false);
}

#[test]
fn ready_succeeds_only_while_a_serve_holds_the_directory() {
	let rig = Rig::new("bot-ready");
	let (before, ok) = rig.run("ready", json!({}));
	assert!(!ok && before["error"]["class"] == "not-ready", "{before}");
	let bot = rig.serve(json!({}), None);
	// Access is known to be active once the first read of the session answers.
	eventually("ready while serving", || rig.run("ready", json!({})).1.then_some(()));
	bot.terminate();
	let (after, ok) = rig.run("ready", json!({}));
	assert!(!ok && after["error"]["class"] == "not-ready", "{after}");
}

#[test]
fn a_setting_variable_reaches_serve() {
	let rig = Rig::new("bot-variables");
	let env = [("GLOWCAP_ROOMS_BOT_DEADLINE", "0")];
	let (refused, ok) = rig.run_env("serve", json!({"rooms-dir": [rig.rooms], "harness": ["fake"]}), &env);
	assert!(!ok && refused["error"]["class"] == "config", "{refused}");
	assert!(
		refused["error"]["message"].as_str().unwrap().contains("--deadline"),
		"{refused}"
	);
	// The variable names a harness the flags left out.
	let env = [("GLOWCAP_ROOMS_BOT_HARNESS", "nope")];
	let (refused, ok) = rig.run_env(
		"serve",
		json!({"rooms-dir": [rig.rooms], "glowcap": [rig.glowcap()]}),
		&env,
	);
	assert!(
		!ok && refused["error"]["message"].as_str().unwrap().contains("nope"),
		"{refused}"
	);
}

#[test]
fn a_first_run_refused_for_its_agent_and_permission_stores_nothing() {
	let rig = Rig::new("bot-refused-first-run");
	let link = "ocapn://wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd.onion/s/eQjP4nR28ffX5eoNCK5DWH6DT_d7BIqD3-My459CUbU";
	let named = json!({"link": ["-"], "harness": ["pi"], "glowcap": [rig.glowcap()]});
	let (refused, ok) = rig.run_fed("serve", named, &format!("{link}\n"));
	assert!(!ok);
	assert_eq!(refused["error"]["class"], "config");
	let message = refused["error"]["message"].as_str().unwrap();
	assert!(message.contains("--permission"), "{message}");
	LinkSecret::of(link).assert_absent(message, "the refusal");
	rig.assert_keeps_no_link([link]);
	for stored in ["session.link", "config.json", "turns.json", "peer.json"] {
		assert!(!rig.dir.join(stored).exists(), "a refused first run stored {stored}");
	}
}

#[test]
fn a_damaged_or_missing_ledger_is_refused_and_left_for_inspection() {
	let rig = Rig::new("bot-ledger-start");
	rig.serve(json!({}), None).stop();
	let ledger = rig.dir.join("turns.json");
	std::fs::write(&ledger, "{").unwrap();
	let (refused, ok) = rig.run("serve", json!({"rooms-dir": [rig.rooms]}));
	assert!(!ok);
	assert_eq!(refused["error"]["class"], "storage");
	assert!(
		refused["error"]["message"].as_str().unwrap().contains("turns.json"),
		"{refused}"
	);
	assert_eq!(
		std::fs::read_to_string(&ledger).unwrap(),
		"{",
		"the damaged ledger was touched"
	);

	std::fs::remove_file(&ledger).unwrap();
	rig.direct(1, "c1", "reply:must not be answered from scratch");
	let (refused, ok) = rig.run("serve", json!({"rooms-dir": [rig.rooms]}));
	assert!(!ok);
	assert_eq!(refused["error"]["class"], "storage");
	assert!(
		refused["error"]["message"].as_str().unwrap().contains("missing"),
		"{refused}"
	);
	assert!(!ledger.exists() && rig.sent().is_empty());
}

/// More conversations than the ledger has rows each ask once, one more asks,
/// and then each of the first asks again. Every one of them is answered,
/// across a restart in the middle, and none waits for good behind finished
/// turns. The ledger holds at most `MAX_ROWS` rows, which `ROWS` equals, and a
/// unit test of the ledger holds the two together.
#[test]
fn more_conversations_than_ledger_rows_are_all_answered_across_a_restart() {
	const ROWS: u64 = 32;
	let rig = Rig::new("bot-crowd");
	let last = 2 * ROWS + 1;
	let bot = rig.serve(json!({}), None);
	// One write, so the bot reads every trigger before any turn ends.
	let rows: String = (1..=last)
		.map(|at| {
			let conversation = match at {
				at if at <= ROWS => format!("c{at}"),
				at if at == ROWS + 1 => "x".to_owned(),
				at => format!("c{}", at - ROWS - 1),
			};
			let row =
				json!({"at": at, "conversation": conversation, "kind": "direct", "text": format!("reply:line {at}")});
			format!("{row}\n")
		})
		.collect();
	std::io::Write::write_all(
		&mut std::fs::OpenOptions::new()
			.append(true)
			.create(true)
			.open(rig.rooms.join("inbox.jsonl"))
			.unwrap(),
		rows.as_bytes(),
	)
	.unwrap();
	eventually("some turns to finish", || {
		(rig.status()["status"]["turns_finished"].as_u64()? >= 8).then_some(())
	});
	assert!(bot.stop().success(), "the bot exited with a failure");
	let bot = rig.serve(json!({}), None);
	rig.wait_for_cursor(last);
	assert!(bot.stop().success(), "the bot exited with a failure");
	let sent = rig.sent();
	let answered: std::collections::BTreeSet<_> = sent
		.iter()
		.map(|line| line["conversation"].as_str().unwrap().to_owned())
		.collect();
	assert_eq!(answered.len() as u64, ROWS + 1, "a conversation was never answered");
	assert!(
		answered.contains("x"),
		"the conversation that waited was never answered"
	);
	let texts = rig.texts();
	for at in 1..=last {
		assert!(
			texts.contains(&format!("line {at}")),
			"trigger {at} was never answered: {texts:?}"
		);
	}
}
