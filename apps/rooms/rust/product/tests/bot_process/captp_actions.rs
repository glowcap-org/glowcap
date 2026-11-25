//! What the agent does in a turn against a real session: it posts, sends,
//! edits, and reads through the bot's verbs, and the session stays open.
use super::captp::{BOT, ROOM, World, action};
use super::captp_direct::{output, turn};
use super::rig::eventually;
use super::session_rig::{call, call_when_paced, try_call};
use super::words;
use rooms_application::content::session::custody::MAX_EFFECTS;
use serde_json::{Value, json};
use std::time::Duration;

/// How long to wait before asking a pacing session again.
const PACE: Duration = Duration::from_secs(1);

/// A session command may post anywhere the access reaches, so it is refused
/// unless its first log line is written, as a post elsewhere is.
#[test]
fn a_command_is_refused_when_its_log_line_cannot_be_written() {
	let world = World::new("bot-live-command-unlogged");
	let bot = world.serve();
	let log = world.rig.dir.join("bot.log");
	std::fs::remove_file(&log).unwrap();
	// A directory where the log goes makes every append fail.
	std::fs::create_dir(&log).unwrap();
	assert_eq!(turn(&world, &[action("command", json!({}), &["workspace"])]), "exit=1");
	let refused = output(&world, 0);
	let message = refused["error"]["message"].as_str().unwrap();
	assert!(message.contains(words::COMMAND_LOG_FAILED), "{refused}");
	std::fs::remove_dir(&log).unwrap();
	world.stopped(bot);
	world.finish();
}

#[test]
fn the_harness_posts_sends_edits_and_reads_the_workspace_through_the_verbs() {
	let world = World::new("bot-live-verbs");
	let bot = world.serve();
	world.dm("reply:ready");
	world.await_line("direct", "ready");
	let room = world.fixture.room_id(0);
	let dir = &world.rig.dir;
	// `send` posts only files inside the turn's own working directory, to the
	// turn's conversation unless `--conversation` names another.
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
		action(
			"send",
			json!({"conversation": [room], "text": ["room caption"], "file": [attachment]}),
			&[]
		),
	]);
	world.dm(&format!("act:{requests}"));
	world.await_line("direct", "exit=0 exit=0 exit=0 exit=0 exit=0");
	world.await_line("room", "said by action");
	world.await_line("direct", "said here");
	let in_room = eventually("the file sent to the room", || {
		world.seen().into_iter().find(|line| line.text == "room caption")
	});
	assert_eq!((in_room.kind.as_str(), in_room.files), ("room", 1));
	let captioned = eventually("the captioned file", || {
		world.seen().into_iter().find(|line| line.text == "file caption")
	});
	assert_eq!(captioned.files, 1);
	assert_eq!(captioned.kind, "direct", "send posted outside the turn's conversation");
	let log = world.rig.log();
	let before = log.find(&format!("is posting to conversation {room} under operation"));
	let after = log.find(&format!("posted to conversation {room} under operation"));
	assert!(
		before.is_some() && after.is_some_and(|after| before < Some(after)),
		"a line in another conversation was not logged before and after: {log}"
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
		world.rig.log().contains(&words::command_running("editLine", "")),
		"a session command was not logged: {}",
		world.rig.log()
	);
	let log = world.rig.log();
	let ran = words::command_ran("editLine", edited["operation"].as_str().unwrap(), "status committed");
	assert!(log.contains(&ran), "a session command's outcome was not logged: {log}");
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
		!world.rig.log().contains(words::COULD_NOT_SHOW_TYPING)
			&& !world.rig.log().contains(words::COULD_NOT_STOP_TYPING),
		"a typing notice failed: {}",
		world.rig.log()
	);
	world.stopped(bot);
	assert_eq!(world.count("room", "said by action"), 1);
	assert_eq!(world.count("room", "edited by hand"), 1);
	world.finish();
}

/// A posting command whose line committed reports that it posted even when
/// keeping it failed for a reason that clears with time, so the agent does
/// not post it again. The bot holds the receipt, which keeps the line's edit
/// and withdraw authority, leaves the claim to the serving loop, and keeps
/// the line on its sweep.
fn posted_then_kept_by_the_sweep(name: &str, fault: &str, text: &str, reason: &str) {
	let world = World::new(name);
	let bot = world.serve_at(Some(fault));
	let room = world.fixture.room_id(0);
	let posting = ["say", room.as_str(), text];
	world.dm(&format!("act:{}", json!([action("command", json!({}), &posting)])));
	world.await_line("direct", "exit=0");
	world.await_line("room", text);
	let output = world.rig.act_output(0);
	assert_eq!(
		(
			&output["ok"],
			&output["status"],
			&output["kept"],
			&output["receipt"],
			&output["settling"]
		),
		(
			&json!(true),
			&json!("committed"),
			&json!(false),
			&json!("held"),
			&json!("bot")
		),
		"{output}"
	);
	assert!(output["base"].is_u64() && output["operation"].is_string(), "{output}");
	assert!(output["reason"].as_str().unwrap().contains(reason), "{output}");
	// The sweep, not the verb, keeps the line: it adopts what the held receipt
	// still names, so nothing gave the receipt back.
	eventually("the sweep to keep the line", || {
		world.rig.log().contains(words::ACTION_KEPT).then_some(())
	});
	eventually("the lane to free", || {
		(world.rig.status()["status"]["sending"] == 0).then_some(())
	});
	world.stopped(bot);
	assert!(!world.rig.log().contains(words::DID_NOT_SETTLE), "{}", world.rig.log());
	assert_eq!(world.count("room", text), 1);
	let owner = call_when_paced(
		&world.fixture.peers[0].state,
		"reply",
		json!({"room": [ROOM], "text": ["the owner still commands"]}),
	);
	assert_eq!(owner["status"], "committed", "{owner}");
	// The count fills every free place, so it comes last.
	assert_eq!(
		world.free_places(),
		MAX_EFFECTS,
		"the kept line's receipt still holds a place"
	);
	world.finish();
}

#[test]
fn a_command_that_posted_but_could_not_read_the_workspace_holds_its_receipt_until_the_sweep_keeps_it() {
	posted_then_kept_by_the_sweep("bot-live-keep-read", "view:keep-read", "posted, not kept", "keep-read");
}

/// A line the workspace refuses for good, as a conversation that is gone or
/// authority that changed does, has its receipt given back: nothing would ever
/// keep it, so the bot leaves no claim to the sweep.
#[test]
fn a_command_whose_line_the_workspace_refuses_for_good_has_its_receipt_given_back() {
	let world = World::new("bot-live-keep-refused");
	let bot = world.serve_at(Some("view:keep-refused"));
	let room = world.fixture.room_id(0);
	let posting = ["say", room.as_str(), "posted, refused"];
	world.dm(&format!("act:{}", json!([action("command", json!({}), &posting)])));
	world.await_line("direct", "exit=0");
	world.await_line("room", "posted, refused");
	let work = std::fs::read_dir(world.rig.dir.join("work")).unwrap().flatten();
	let output = work
		.map(|conversation| conversation.path().join("act-0.out"))
		.find(|path| path.exists())
		.unwrap();
	let output: Value = serde_json::from_slice(&std::fs::read(output).unwrap()).unwrap();
	assert_eq!(
		(
			&output["ok"],
			&output["status"],
			&output["kept"],
			&output["receipt"],
			&output["settling"]
		),
		(
			&json!(true),
			&json!("committed"),
			&json!(false),
			&json!("released"),
			&Value::Null
		),
		"{output}"
	);
	assert!(output["reason"].as_str().unwrap().contains("keep-refused"), "{output}");
	eventually("the lane to free", || {
		(world.rig.status()["status"]["sending"] == 0).then_some(())
	});
	world.stopped(bot);
	assert_eq!(world.count("room", "posted, refused"), 1);
	assert_eq!(
		world.free_places(),
		MAX_EFFECTS,
		"the given-back receipt still holds a place"
	);
	world.finish();
}

#[test]
fn a_command_whose_keeping_met_a_moving_workspace_on_every_attempt_holds_its_receipt_until_the_sweep_keeps_it() {
	posted_then_kept_by_the_sweep(
		"bot-live-keep-conflict",
		"view:keep-conflict",
		"posted, workspace moving",
		"workspace",
	);
}

/// A command whose result carries a capability the bot does not keep, such as
/// a room link, is refused before it is sent: the agent reads that nothing
/// was sent, with no operation to look at, and no claim is left.
#[test]
fn a_command_whose_result_nothing_keeps_is_refused_before_it_is_sent() {
	let world = World::new("bot-live-unkeepable");
	let bot = world.serve();
	let room = world.fixture.room_id(0);
	let linking = ["ensureRoomLink", room.as_str()];
	let act = format!("act:{}", json!([action("command", json!({}), &linking)]));
	world.dm(&act);
	// A refused verb exits 1 and prints why.
	world.await_line("direct", "exit=1");
	let work = std::fs::read_dir(world.rig.dir.join("work")).unwrap().flatten();
	let output = work
		.map(|conversation| conversation.path().join("act-0.out"))
		.find(|path| path.exists())
		.unwrap();
	let output: Value = serde_json::from_slice(&std::fs::read(output).unwrap()).unwrap();
	assert_eq!(
		(&output["ok"], &output["error"]["class"], &output["error"]["operation"]),
		(&json!(false), &json!("unkeepable"), &Value::Null),
		"{output}"
	);
	let message = output["error"]["message"].as_str().unwrap_or_default();
	assert!(message.starts_with("nothing was sent"), "{output}");
	let claims = std::fs::read_dir(world.rig.dir.join("turn-actions")).map_or(0, |entries| entries.count());
	assert_eq!(claims, 0, "a refused command leaves no claim");
	eventually("the lane to free", || {
		(world.rig.status()["status"]["sending"] == 0).then_some(())
	});
	world.stopped(bot);
	// The session holds no receipt of it, so every place is free, and the
	// direct conversation holds only the friend's line and the reply.
	assert_eq!(world.free_places(), MAX_EFFECTS, "a refused command took a place");
	let seen = world.seen();
	assert!(
		seen.iter()
			.filter(|line| line.kind == "direct" && line.line.is_some())
			.all(|line| line.text == act || line.text == "exit=1"),
		"a refused command left a line: {seen:?}"
	);
	world.finish();
}

/// A command whose line was kept while the answer to keeping it was lost
/// reports it kept, because the session answers the give-back that follows
/// with kept and changes nothing.
#[test]
fn a_command_kept_while_its_answer_was_lost_reports_it_kept() {
	let world = World::new("bot-live-keep-lost");
	let bot = world.serve_at(Some("view:keep-lost"));
	let room = world.fixture.room_id(0);
	let posting = ["say", room.as_str(), "kept, answer lost"];
	world.dm(&format!("act:{}", json!([action("command", json!({}), &posting)])));
	world.await_line("direct", "exit=0");
	world.await_line("room", "kept, answer lost");
	let work = std::fs::read_dir(world.rig.dir.join("work")).unwrap().flatten();
	let output = work
		.map(|conversation| conversation.path().join("act-0.out"))
		.find(|path| path.exists())
		.unwrap();
	let output: Value = serde_json::from_slice(&std::fs::read(output).unwrap()).unwrap();
	assert_eq!(
		(&output["ok"], &output["status"], &output["kept"]),
		(&json!(true), &json!("committed"), &Value::Null),
		"{output}"
	);
	eventually("the lane to free", || {
		(world.rig.status()["status"]["sending"] == 0).then_some(())
	});
	world.stopped(bot);
	assert_eq!(world.count("room", "kept, answer lost"), 1);
	// The kept receipt was given back, so it holds no place.
	assert_eq!(world.free_places(), MAX_EFFECTS, "the kept receipt still holds a place");
	world.finish();
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
	let owner = eventually("the session to take its owner's command", || {
		match try_call(
			&world.fixture.peers[0].state,
			"reply",
			json!({"room": [ROOM], "text": ["the owner still commands"]}),
		) {
			Ok(done) => Some(done),
			Err(output) if output.contains(r#""retry":"soon""#) => {
				// The session paces a burst, and asking again sooner than its
				// pace keeps it paced.
				std::thread::sleep(PACE);
				None
			}
			Err(output) => panic!(
				"the session refused its owner: {output}\n{}\n{}\n{}",
				world.rig.log(),
				world.rig.status(),
				call(&world.fixture.peers[0].state, "status", json!({}))
			),
		}
	});
	assert_eq!(owner["status"], "committed", "{owner}");
	for (turn, reply) in replies.iter().enumerate() {
		for (n, _) in reply.split(' ').enumerate().filter(|(_, exit)| *exit == "exit=0") {
			world.await_line("room", &text(turn, n));
		}
	}
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
		!log.contains("receipt is still held")
			&& !log.contains(rooms_application::failure::FailureCode::ReceiptsFull.wire()),
		"{log}"
	);
	world.finish();
}
