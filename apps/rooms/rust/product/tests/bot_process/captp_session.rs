//! The bot against a real session whose access or process changes under it:
//! access paused and resumed or revoked, and the session stopped and started.
use super::captp::{DWELL, World};
use super::rig::eventually;
use super::session_rig::run_within;
use serde_json::json;
use std::time::Duration;

#[test]
fn paused_access_keeps_the_message_until_it_resumes() {
	let world = World::new("bot-live-access");
	run_within(Duration::from_secs(60), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		let bot = world.rig.serve_linked(&issued.link, json!({"model": ["test-model"]}));
		assert_eq!(
			world.rig.status()["agent"],
			json!({
				"harness": "fake", "model": "test-model", "permission": "safe",
				"conversation_work_root": world.rig.dir.join("work"),
			})
		);

		let config = world.rig.dir.join("config.json");
		let mut saved: serde_json::Value = serde_json::from_slice(&std::fs::read(&config).unwrap()).unwrap();
		saved["model"] = json!("next-model");
		saved["permission"] = json!("full");
		std::fs::write(config, serde_json::to_vec(&saved).unwrap()).unwrap();
		let report = world.rig.status();
		assert_eq!(report["agent"]["model"], "next-model");
		assert_eq!(report["agent"]["permission"], "full");
		assert_eq!(report["status"]["model"], "test-model");
		assert_eq!(report["status"]["permission"], "safe");

		world.dm("reply:first");
		world.await_line("direct", "first");

		grants.pause(&issued.name).await.unwrap();
		eventually("status to show paused", || (world.access() == "paused").then_some(()));
		world.dm("reply:held while paused");
		std::thread::sleep(DWELL);
		assert_eq!(world.count("direct", "held while paused"), 0);
		grants.resume(&issued.name).await.unwrap();
		world.await_line("direct", "held while paused");
		eventually("access to reopen", || (world.access() == "active").then_some(()));
		world.dm("reply:after resume");
		world.await_line("direct", "after resume");
		assert_eq!(world.count("direct", "held while paused"), 1);

		assert!(bot.stop().success(), "the bot exited with a failure");
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
		assert_eq!(
			world.count("direct", "held while paused"),
			1,
			"the paused message was answered again"
		);
		assert_eq!(world.count("direct", "after resume"), 1);
	});
	world.finish();
}

#[test]
fn a_session_that_stops_and_starts_again_is_reattached_and_answers_the_next_message() {
	let mut world = World::new("bot-live-restart");
	let bot = world.serve();
	world.dm("reply:before the restart");
	world.await_line("direct", "before the restart");
	world.fixture.peers[0].restart();
	world.dm_again("reply:after the restart");
	world.await_line("direct", "after the restart");
	assert_eq!(world.count("direct", "before the restart"), 1);
	assert_eq!(world.rig.status()["running"], true);
	assert_eq!(
		world.rig.status()["status"]["gaps"],
		1,
		"the restart was not counted as a gap"
	);
	world.stopped(bot);
	assert_eq!(
		world.count("direct", "after the restart"),
		1,
		"the message was answered more than once"
	);
	assert_eq!(world.count("direct", "before the restart"), 1);
	world.finish();
}

#[test]
fn a_revoked_access_ends_the_bot_with_a_failure_and_answers_nothing_again() {
	let world = World::new("bot-live-revoked");
	run_within(Duration::from_secs(60), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		let mut bot = world.rig.serve_linked(&issued.link, json!({}));
		world.dm("reply:before the revoke");
		world.await_line("direct", "before the revoke");
		grants.revoke(&issued.name).await.unwrap();
		// The operator text and the revoked status are the stand-in test's
		// subject. This one proves the exit and that nothing is answered again.
		assert!(!bot.process.wait().success(), "revoked access left the bot serving");
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
		assert_eq!(world.count("direct", "before the revoke"), 1);
	});
	world.finish();
}
