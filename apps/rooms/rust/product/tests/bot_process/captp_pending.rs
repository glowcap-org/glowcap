//! A reply the bot has yet to send, against a real session whose access
//! refuses or pauses the link it is served with. No case ends with a failure
//! line, and each counts what was posted.
//! Each `DWELL` proves an absence: no event says no further line is coming.
use super::captp::{DWELL, World};
use super::rig::eventually;
use super::session_rig::{assert_same_secret, run_within};
use super::words;
use serde_json::json;
use std::time::Duration;

/// A long answer posts as two lines, the first starting `p0 ` and the last
/// `p8 `.
const LONG: &str = "long:9000";

fn first(world: &World) -> usize {
	world.count_starting("direct", "p0 ")
}

fn last(world: &World) -> usize {
	world.count_starting("direct", "p8 ")
}

fn no_failure_line(world: &World) {
	let failed = world
		.seen()
		.iter()
		.filter(|line| line.text.starts_with(words::COULD_NOT_ANSWER))
		.count();
	assert_eq!(failed, 0, "a failure line replaced the reply");
}

/// The old access is still valid, so it settles the line it sent before the
/// replacement is opened, and the refused replacement changes nothing.
#[test]
fn a_replacement_the_session_refuses_leaves_the_old_access_to_finish_its_line() {
	let world = World::new("bot-live-old-finishes");
	run_within(Duration::from_secs(60), async {
		let (issuer, grants, terms) = world.issuer().await;
		let accepted = grants.issue("the bot", &terms).await.unwrap();
		let refused = grants.issue("the refused replacement", &terms).await.unwrap();
		grants.revoke(&refused.name).await.unwrap();

		let mut bot = world
			.rig
			.serve_linked_at(&accepted.link, json!({}), Some("before-send"));
		world.dm("reply:finished by the old access");
		assert!(!bot.process.wait().success(), "the bot was not killed before its send");
		assert_eq!(world.count("direct", "finished by the old access"), 0);
		let stored = std::fs::read(world.rig.dir.join("session.link")).unwrap();

		let mut replaced = world.rig.serve_refused(&refused.link, true);
		assert!(!replaced.wait().success(), "a revoked replacement left the bot serving");
		eventually("the replacement-refused failure", || {
			world
				.rig
				.output()
				.contains(words::REPLACEMENT_NOT_ACCEPTED)
				.then_some(())
		});
		world.await_line("direct", "finished by the old access");
		std::thread::sleep(DWELL);
		assert_eq!(world.count("direct", "finished by the old access"), 1);
		assert_same_secret(
			std::fs::read(world.rig.dir.join("session.link")).unwrap(),
			&stored,
			"a refused replacement changed the stored link",
		);
		no_failure_line(&world);
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A committed first segment stands; a revoked grant cannot send the rest
/// of its private answer through a different grant on the same session.
#[test]
fn a_private_reply_stops_after_its_original_grant_is_revoked() {
	let world = World::new("bot-live-pending");
	run_within(Duration::from_secs(90), async {
		let (issuer, grants, terms) = world.issuer().await;
		let old = grants.issue("the bot", &terms).await.unwrap();
		let refused = grants.issue("the refused replacement", &terms).await.unwrap();
		grants.revoke(&refused.name).await.unwrap();

		let mut bot = world.rig.serve_linked_at(&old.link, json!({}), Some("after-record"));
		world.dm(LONG);
		assert!(
			!bot.process.wait().success(),
			"the bot was not killed after its first line"
		);
		eventually("the reply's first line", || (first(&world) == 1).then_some(()));
		assert_eq!((first(&world), last(&world)), (1, 0));
		grants.revoke(&old.name).await.unwrap();

		let mut replaced = world.rig.serve_refused(&refused.link, true);
		assert!(!replaced.wait().success(), "a revoked replacement left the bot serving");
		std::thread::sleep(DWELL);
		assert_eq!(last(&world), 0, "a refused link sent the reply");
		assert_eq!(world.rig.status()["status"]["unconfirmed"], 0);
		no_failure_line(&world);

		let good = grants.issue("the good replacement", &terms).await.unwrap();
		let bot = world.rig.serve_replacing(&good.link);
		eventually("the original private reply to close on the changed grant", || {
			world
				.rig
				.log()
				.contains("closed before posting to a changed destination")
				.then_some(())
		});
		assert_eq!((first(&world), last(&world)), (1, 0));
		no_failure_line(&world);
		assert!(bot.stop().success(), "the bot exited with a failure");
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A restart on a stored link whose access is paused holds the reply, and
/// posts it once when the access resumes.
#[test]
fn a_reply_waits_for_a_paused_access_after_a_restart_and_posts_once_on_resume() {
	let world = World::new("bot-live-paused-restart");
	run_within(Duration::from_secs(90), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();

		let mut bot = world.rig.serve_linked_at(&issued.link, json!({}), Some("after-record"));
		world.dm(LONG);
		assert!(
			!bot.process.wait().success(),
			"the bot was not killed after its first line"
		);
		eventually("the reply's first line", || (first(&world) == 1).then_some(()));
		assert_eq!((first(&world), last(&world)), (1, 0));
		grants.pause(&issued.name).await.unwrap();

		// The stored link serves again, but the session reads it as paused, so
		// the bot reports no serving line.
		let mut again = world.rig.serve_refused(&issued.link, false);
		eventually("status to show paused", || (world.access() == "paused").then_some(()));
		std::thread::sleep(DWELL);
		assert_eq!(last(&world), 0, "a paused access sent the reply");
		grants.resume(&issued.name).await.unwrap();
		eventually("the rest of the reply", || (last(&world) == 1).then_some(()));
		std::thread::sleep(DWELL);
		assert_eq!((first(&world), last(&world)), (1, 1));
		no_failure_line(&world);
		again.signal("-TERM");
		assert!(again.wait().success(), "the bot exited with a failure");
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}
