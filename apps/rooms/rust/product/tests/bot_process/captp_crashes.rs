//! The bot killed or slowed at each step of a send against a real session.
//! Every case ends with the reply posted exactly once, no failure line, and a
//! session that still takes commands.
use super::captp::{ROOM, World};
use super::rig::eventually;
use super::session_rig::call_when_paced;
use serde_json::json;

/// Wait for `text` in the private conversation, then for the bot to close
/// every turn.
pub(super) fn answered(world: &World, text: &str) {
	world.await_line("direct", text);
	eventually("every turn to close", || {
		(world.rig.status()["status"]["open_turns"] == 0).then_some(())
	});
}

/// Each reply was posted once, nothing else was, and the bot's session still
/// takes a command of its own.
pub(super) fn once_and_still_open(world: &World, texts: &[&str]) {
	let seen = world.seen();
	for text in texts {
		let posted = seen
			.iter()
			.filter(|line| line.kind == "direct" && line.text == *text)
			.count();
		assert_eq!(posted, 1, "{text}: {seen:?}");
	}
	let failures = seen
		.iter()
		.filter(|line| line.text.starts_with("I could not answer that"))
		.count();
	assert_eq!(failures, 0, "a failure line was posted: {seen:?}");
	still_open(world);
	assert_eq!(world.rig.status()["status"]["unconfirmed"], 0);
	let log = world.rig.log();
	assert!(!log.contains("would not keep it"), "{log}");
	assert!(!log.contains("kept the receipt"), "{log}");
	assert!(!log.contains("the old access"), "{log}");
}

/// The bot's session still takes a command of its own, so no receipt the bot
/// left behind fills it.
pub(super) fn still_open(world: &World) {
	let other = call_when_paced(
		&world.fixture.peers[0].state,
		"reply",
		json!({"room": [ROOM], "text": ["the session still takes commands"]}),
	);
	assert_eq!(other["status"], "committed", "{other}");
}

/// Kill the bot at `point` while it answers `text`, then restart it.
pub(super) fn killed_at(world: &World, point: &str, text: &str) {
	let mut bot = world.serve_at(Some(point));
	world.dm(&format!("reply:{text}"));
	assert!(!bot.process.wait().success(), "the bot was not killed at {point}");
}

#[test]
fn a_bot_killed_after_the_send_with_commands_in_between_posts_once() {
	let world = World::new("bot-live-after-send");
	killed_at(&world, "after-send", "after the send");
	// More commands than the session holds receipts for.
	for n in 0..12 {
		let sent = call_when_paced(
			&world.fixture.peers[0].state,
			"reply",
			json!({"room": [ROOM], "text": [format!("someone else {n}")]}),
		);
		assert_eq!(sent["status"], "committed", "{sent}");
	}
	let bot = world.serve();
	answered(&world, "after the send");
	world.stopped(bot);
	once_and_still_open(&world, &["after the send"]);
	let log = world.rig.log();
	assert!(
		!log.contains("holds no receipt for operation"),
		"a committed send was sent again: {log}"
	);
	world.fixture.finish();
}

#[test]
fn a_bot_killed_before_its_send_left_posts_once_after_restart() {
	let world = World::new("bot-live-before-send");
	killed_at(&world, "before-send", "never received");
	let bot = world.serve();
	answered(&world, "never received");
	world.stopped(bot);
	once_and_still_open(&world, &["never received"]);
	let log = world.rig.log();
	assert!(log.contains("holds no receipt for operation"), "{log}");
	world.fixture.finish();
}

#[test]
fn a_bot_killed_after_the_commit_and_a_send_slower_than_its_deadline_each_post_once() {
	let world = World::new("bot-live-commit-late");
	killed_at(&world, "after-commit", "after the commit");
	let bot = world.serve_at(Some("late-send"));
	answered(&world, "after the commit");
	world.dm("reply:slower than its deadline");
	answered(&world, "slower than its deadline");
	world.stopped(bot);
	once_and_still_open(&world, &["after the commit", "slower than its deadline"]);
	let log = world.rig.log();
	assert!(log.contains("the session did not answer in time"), "{log}");
	assert!(
		!log.contains("holds no receipt for operation"),
		"a committed send was sent again: {log}"
	);
	world.fixture.finish();
}
