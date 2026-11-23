//! What the agent does in a turn against a real session: it posts, sends,
//! edits, and reads through the bot's verbs, and the session stays open.
use super::captp::{BOT, ROOM, World, action};
use super::rig::{WAIT, eventually};
use super::session_rig::{call, call_when_paced, try_call};
use serde_json::{Value, json};
use std::time::{Duration, Instant};

#[test]
fn the_harness_posts_sends_edits_and_reads_the_workspace_through_the_verbs() {
	let world = World::new("bot-live-verbs");
	let bot = world.serve();
	world.dm("reply:ready");
	world.await_line("direct", "ready");
	let room = world.fixture.room_id(0);
	let dir = &world.rig.dir;
	// `send` posts only files inside the turn's own working directory, and
	// only to the turn's conversation.
	let workdir = std::fs::read_dir(dir.join("work"))
		.unwrap()
		.flatten()
		.next()
		.unwrap()
		.path();
	let attachment = workdir.join("note.txt");
	std::fs::write(&attachment, "a file from the bot").unwrap();
	let requests = json!([
		action("say", json!({"conversation": [room], "text": ["said by action"]}), &[]),
		action("send", json!({"text": ["file caption"], "file": [attachment]}), &[]),
		action("workspace", json!({}), &[]),
		action("say", json!({"text": ["said here"]}), &[]),
	]);
	world.dm(&format!("act:{requests}"));
	world.await_line("direct", "exit=0 exit=0 exit=0 exit=0");
	world.await_line("room", "said by action");
	world.await_line("direct", "said here");
	let captioned = eventually("the captioned file", || {
		world.seen().into_iter().find(|line| line.text == "file caption")
	});
	assert_eq!(captioned.files, 1);
	assert_eq!(captioned.kind, "direct", "send posted outside the turn's conversation");
	assert!(
		world.rig.log().contains(&format!("posted to conversation {room}")),
		"a line in another conversation was not logged: {}",
		world.rig.log()
	);
	assert_eq!(world.rig.act_output(0)["status"], "committed");
	let workspace = world.rig.act_output(2);
	assert_eq!(workspace["ok"], true);
	let conversations = workspace["workspace"]["conversations"].to_string();
	assert!(
		conversations.contains(&room) && conversations.contains("direct"),
		"{workspace}"
	);
	assert!(workspace["workspace"].to_string().contains(BOT), "{workspace}");

	// An edit through the verb, in a later turn.
	let (id, _) = world
		.seen()
		.into_iter()
		.find_map(|line| line.line.filter(|_| line.text == "said by action"))
		.unwrap();
	let line = id.to_string();
	let edit = ["editLine", room.as_str(), line.as_str(), "edited by hand"];
	world.dm(&format!("act:{}", json!([action("command", json!({}), &edit)])));
	world.await_line("direct", "exit=0");
	world.await_line("room", "edited by hand");
	let edited = world.rig.act_output(0);
	assert_eq!(edited["status"], "committed", "{edited}");
	assert!(
		world.rig.log().contains("ran session command editLine under operation"),
		"a session command was not logged: {}",
		world.rig.log()
	);
	// Observing the same operation reports it again and posts nothing new. A
	// refusal is a typed error and a nonzero exit.
	let (operation, base) = (edited["operation"].as_str().unwrap(), edited["base"].to_string());
	let requests = json!([
		action("command", json!({"operation": [operation], "base": [base]}), &edit),
		action("command", json!({}), &["noSuchCommand"]),
	]);
	world.dm(&format!("act:{requests}"));
	let exits = eventually("the second edit turn's reply", || {
		world.seen().into_iter().find(|line| {
			line.kind == "direct" && line.text.starts_with("exit=0 exit=") && line.text.split(' ').count() == 2
		})
	});
	assert_ne!(exits.text, "exit=0 exit=0", "the unknown command succeeded");
	let again = world.rig.act_output(0);
	assert_eq!(again["status"], "committed", "{again}");
	assert_eq!(world.count("room", "edited by hand"), 1);
	let refused = world.rig.act_output(1);
	assert_eq!(refused["ok"], false);
	assert!(
		refused["error"]["class"].is_string() && refused["error"]["retry"].is_string(),
		"{refused}"
	);
	// No typing notice the bot sent through the session failed.
	assert!(
		!world.rig.log().contains("showing typing") && !world.rig.log().contains("show typing"),
		"a typing notice failed: {}",
		world.rig.log()
	);
	world.stopped(bot);
	assert_eq!(world.count("room", "said by action"), 1);
	assert_eq!(world.count("room", "edited by hand"), 1);
	world.fixture.finish();
}

/// A posting command whose line committed reports that it posted even when
/// the read that would keep the line fails, so the agent does not post it
/// again, and its receipt is given back.
#[test]
fn a_command_that_posted_but_could_not_be_kept_reports_the_post_and_releases_its_receipt() {
	let world = World::new("bot-live-keep-read");
	let bot = world.serve_at(Some("view:keep-read"));
	let room = world.fixture.room_id(0);
	let posting = ["say", room.as_str(), "posted, not kept"];
	world.dm(&format!("act:{}", json!([action("command", json!({}), &posting)])));
	world.await_line("direct", "exit=0");
	world.await_line("room", "posted, not kept");
	let output = world.rig.act_output(0);
	assert_eq!(
		(&output["ok"], &output["status"], &output["kept"], &output["receipt"]),
		(&json!(true), &json!("committed"), &json!(false), &json!("released")),
		"{output}"
	);
	assert!(output["base"].is_u64() && output["operation"].is_string(), "{output}");
	assert!(output["reason"].as_str().unwrap().contains("keep-read"), "{output}");
	world.stopped(bot);
	assert_eq!(world.count("room", "posted, not kept"), 1);
	let owner = call_when_paced(
		&world.fixture.peers[0].state,
		"reply",
		json!({"room": [ROOM], "text": ["the owner still commands"]}),
	);
	assert_eq!(owner["status"], "committed", "{owner}");
	world.fixture.finish();
}

/// Two turns back to back, each posting through `command` until the turn's
/// actions run out, keep every line they post, so the session still takes
/// its owner's next command. The session paces a burst like this, so a
/// command it asks to wait is tried again, and no other refusal is accepted.
#[test]
fn turns_that_post_through_every_action_they_may_take_leave_the_session_open() {
	use rooms_application::content::session::custody::MAX_EFFECTS;
	// More than a turn may take, so the last are refused.
	const ASKED: usize = 16;
	let world = World::new("bot-live-actions");
	let bot = world.serve();
	let room = world.fixture.room_id(0);
	let text = |turn: usize, n: usize| format!("posted by command {turn}-{n}");
	for turn in 0..2 {
		let requests: Vec<Value> = (0..ASKED)
			.map(|n| action("command", json!({}), &["say", room.as_str(), text(turn, n).as_str()]))
			.collect();
		world.dm(&format!("act:{}", Value::Array(requests)));
	}
	let replies = eventually("both turns' replies", || {
		let replies: Vec<_> = world
			.seen()
			.into_iter()
			.filter(|line| line.kind == "direct" && line.text.starts_with("exit="))
			.map(|line| line.text)
			.collect();
		(replies.len() == 2).then_some(replies)
	});
	let until = Instant::now() + WAIT;
	let owner = loop {
		match try_call(
			&world.fixture.peers[0].state,
			"reply",
			json!({"room": [ROOM], "text": ["the owner still commands"]}),
		) {
			Ok(done) => break done,
			Err(output) if output.contains(r#""retry":"soon""#) && Instant::now() < until => {
				std::thread::sleep(Duration::from_secs(1));
			}
			Err(output) => panic!(
				"the session refused its owner: {output}\n{}\n{}\n{}",
				world.rig.log(),
				world.rig.status(),
				call(&world.fixture.peers[0].state, "status", json!({}))
			),
		}
	};
	assert_eq!(owner["status"], "committed", "{owner}");
	world.stopped(bot);
	let mut posted = 0;
	for (turn, reply) in replies.iter().enumerate() {
		let exits: Vec<_> = reply.split(' ').collect();
		assert_eq!(exits.len(), ASKED, "{reply}");
		assert_ne!(exits[ASKED - 1], "exit=0", "turn {turn} ran past its actions: {reply}");
		for (n, exit) in exits.iter().enumerate() {
			let expected = usize::from(*exit == "exit=0");
			posted += expected;
			assert_eq!(world.count("room", &text(turn, n)), expected, "{turn}-{n}: {reply}");
		}
	}
	assert!(posted > MAX_EFFECTS, "only {posted} lines posted: {replies:?}");
	let log = world.rig.log();
	assert!(
		!log.contains("receipt is still held") && !log.contains("receipts are full"),
		"{log}"
	);
	world.fixture.finish();
}
