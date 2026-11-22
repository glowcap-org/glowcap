//! The bot against a real session whose access or process changes under it:
//! access paused, resumed, and revoked, and the session stopped and started.
use super::captp::{DWELL, World};
use super::rig::eventually;
use super::session_rig::{host, run_within};
use rooms_application::content::session::{Preset, Terms};
use rooms_platform::HostPlatform;
use rooms_services::session::attached::Grants;
use serde_json::json;
use std::time::Duration;

#[test]
fn paused_access_keeps_the_message_until_it_resumes_and_revoked_access_leaves_the_bot_up() {
	let world = World::new("bot-live-access");
	let management = std::fs::read_to_string(world.fixture.peers[0].state.join("management.sturdyref")).unwrap();
	run_within(Duration::from_secs(60), async {
		let issuer = host().await;
		let grants = Grants::attach(&issuer, HostPlatform, &management).await.unwrap();
		let terms = Terms::new(Preset::Collaborator.values()).unwrap();
		let issued = grants.issue("the bot", &terms).await.unwrap();
		let bot = world.rig.serve_linked(&issued.link, json!({}));
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

		grants.revoke(&issued.name).await.unwrap();
		eventually("status to show revoked", || (world.access() == "revoked").then_some(()));
		assert_eq!(world.rig.status()["running"], true, "revoked access stopped the bot");
		// A send can find the access revoked first. Reading finds it too.
		eventually("reading to find the access revoked", || {
			world
				.rig
				.log()
				.lines()
				.any(|line| line.contains("receiving:") && line.contains("this access was revoked"))
				.then_some(())
		});
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
		world.stopped(bot);
		assert_eq!(
			world.count("direct", "held while paused"),
			1,
			"the paused message was answered again"
		);
		assert_eq!(world.count("direct", "after resume"), 1);
	});
	world.fixture.finish();
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
	world.fixture.finish();
}
