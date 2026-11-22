//! What may start a turn: the allow list, the limits on how much anyone can
//! start, the access the session reports, and `/reset`. Also what the bot
//! refuses before it serves, and the agent's commands outside a turn.
use super::rig::{Rig, eventually, gone, recorded_pid};
use serde_json::json;

fn room_line(rig: &Rig, at: u64, sender: &str, text: &str) {
	rig.push(json!({"at": at, "conversation": "r1", "kind": "room", "sender": sender,
		"text": text, "mentions": {"member": true}}));
}

fn direct_from(rig: &Rig, at: u64, conversation: &str, peer: &str, text: &str) {
	rig.push(json!({"at": at, "conversation": conversation, "kind": "direct", "peer": peer, "text": text}));
}

fn texts(rig: &Rig) -> Vec<String> {
	rig.sent()
		.iter()
		.map(|line| line["text"].as_str().unwrap().to_owned())
		.collect()
}

#[test]
fn only_allowed_senders_start_turns_and_nobody_else_reaches_the_agent() {
	let rig = Rig::new("bot-allow");
	let bot = rig.serve(json!({"allow": ["Ann,dave"]}), None);
	room_line(&rig, 1, "bob", "reply:to bob");
	rig.push(json!({"at": 2, "conversation": "r1", "kind": "room", "sender": "bob", "text": "bob aside"}));
	direct_from(&rig, 3, "d-carol", "carol", "reply:to carol");
	room_line(&rig, 4, "ann", "reply:to ann");
	direct_from(&rig, 5, "d-dave", "Dave", "reply:to dave");
	rig.wait_for_cursor(5);
	let mut sent = texts(&rig);
	sent.sort();
	assert_eq!(sent, ["to ann", "to dave"]);
	let log = rig.log();
	assert_eq!(log.matches("ignored a message in").count(), 2, "{log}");
	// Neither a declined trigger nor a line from someone off the list reaches
	// the agent, even as context.
	let prompt = std::fs::read_to_string(rig.workdir("r1").join("prompt.txt")).unwrap();
	assert!(!prompt.contains("to bob") && !prompt.contains("bob aside"), "{prompt}");
	let heard = std::fs::read_to_string(rig.dir.join("conversations.json")).unwrap();
	assert!(
		heard.contains("d-dave") && !heard.contains("d-carol"),
		"a declined sender counted toward the conversations the bot keeps: {heard}"
	);

	// A nickname proves only who holds it now. Ann renamed is not on the list,
	// and whoever holds Ann's name next is.
	direct_from(&rig, 6, "d-ann", "anna", "reply:to anna");
	direct_from(&rig, 7, "d-new", "ANN", "reply:to the new ann");
	rig.wait_for_cursor(7);
	assert!(bot.stop().success(), "the bot exited with a failure");
	let mut sent = texts(&rig);
	sent.sort();
	assert_eq!(sent, ["to ann", "to dave", "to the new ann"]);
}

#[test]
fn replies_in_a_row_to_one_sender_stop_at_the_streak_limit() {
	let rig = Rig::new("bot-streak");
	let bot = rig.serve(json!({"streak-limit": ["2"]}), None);
	for at in 1..=3 {
		direct_from(&rig, at, "d1", "other-bot", &format!("reply:answer {at}"));
		rig.wait_for_cursor(at);
	}
	assert_eq!(texts(&rig), ["answer 1", "answer 2"]);
	assert!(rig.log().contains("too many times in a row"), "{}", rig.log());
	// Another person has a count of their own.
	room_line(&rig, 4, "ann", "reply:ann asks");
	rig.wait_for_cursor(4);
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(texts(&rig).last().unwrap(), "ann asks");
}

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
		rig.log()
			.contains("halted, because the access stopped working")
			.then_some(())
	});
	assert!(rig.sent().is_empty());
	std::fs::write(workdir.join("release"), "").unwrap();
	rig.events_fault(None);
	rig.wait_for_replies(1);
	rig.wait_for_cursor(1);
	assert!(bot.stop().success(), "the bot exited with a failure");
	assert_eq!(texts(&rig), ["after the pause"]);
	let runs = std::fs::read_to_string(workdir.join("runs.log")).unwrap();
	assert_eq!(runs.lines().count(), 2, "{runs}");
	assert_eq!(rig.status()["status"]["turns_finished"], 1);
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
	// Reads keep working. Only the other conversation's send finds the pause.
	rig.send_faults(&["paused"]);
	rig.direct(2, "c2", "reply:sent after the pause");
	eventually("the agent to be ended", || gone(first).then_some(()));
	eventually("the turn to be halted", || {
		rig.log()
			.contains("halted, because the access stopped working")
			.then_some(())
	});
	std::fs::write(workdir.join("release"), "").unwrap();
	rig.wait_for_replies(2);
	rig.wait_for_cursor(2);
	assert!(bot.stop().success(), "the bot exited with a failure");
	let mut answered = texts(&rig);
	answered.sort();
	assert_eq!(answered, ["after the pause", "sent after the pause"]);
	let runs = std::fs::read_to_string(workdir.join("runs.log")).unwrap();
	assert_eq!(runs.lines().count(), 2, "{runs}");
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
	let sent = texts(&rig);
	assert_eq!(sent.len(), 3);
	assert!(sent[1].starts_with("Started a new conversation"), "{sent:?}");
	let runs = std::fs::read_to_string(rig.workdir("c1").join("runs.log")).unwrap();
	assert_eq!(runs.lines().count(), 2, "the reset ran the agent: {runs}");
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
	let sent = texts(&rig);
	assert!(sent[2].contains("instructions file could not be read"), "{sent:?}");
}

#[test]
fn serve_refuses_an_agent_that_is_not_installed_before_storing_anything() {
	let rig = Rig::new("bot-no-agent");
	let empty = rig.dir.with_file_name("empty-path");
	std::fs::create_dir(&empty).unwrap();
	let (refused, ok) = rig.run_env(
		"serve",
		json!({"rooms-dir": [rig.rooms], "harness": ["claude"], "glowcap": [rig.glowcap()]}),
		&[("PATH", empty.to_str().unwrap())],
	);
	assert!(!ok && refused["error"]["class"] == "config", "{refused}");
	// The same shape `session access` prints, retry advice included.
	assert_eq!(refused["error"]["retry"], "after-request-change", "{refused}");
	let message = refused["error"]["message"].as_str().unwrap();
	assert!(message.contains("--harness claude runs claude"), "{message}");
	assert!(
		!rig.dir.join("config.json").exists(),
		"a refused serve stored its settings"
	);
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
	let attached: serde_json::Value =
		serde_json::from_slice(&std::fs::read(rig.workdir("c1").join("act-11.out")).unwrap()).unwrap();
	assert!(
		attached["error"]["message"]
			.as_str()
			.unwrap_or_default()
			.contains("no session link"),
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
			.contains("while a turn"),
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
