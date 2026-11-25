//! A start asks the session whose receipt each line it sent is, before it
//! serves. While that ask waits, `bot status` reports this process and not the
//! one that served before, and `bot ready` fails. An ask the session refuses
//! for good ends the start.
use super::captp::World;
use super::rig::eventually;
use super::session_rig::run_within;
use super::words;
use serde_json::{Value, json};
use std::time::Duration;

/// Serve `link` until the bot is killed after it sent a line the ledger does
/// not know the answer of, and return the pid its status recorded.
fn killed_after_send(world: &World, link: &str) -> u64 {
	let mut bot = world.rig.serve_linked_at(link, json!({}), Some("after-send"));
	let before = world.rig.status()["status"]["pid"].as_u64().unwrap();
	world.dm("reply:asked about");
	assert!(!bot.process.wait().success(), "the bot was not killed after its send");
	assert_eq!(world.rig.status()["status"]["pid"].as_u64().unwrap(), before);
	assert_eq!(world.rig.status()["status"]["access"], "active");
	before
}

/// The status once it names `pid`, which a start writes when it takes the lease.
fn status_of(world: &World, pid: u32) -> Value {
	eventually("the start's own status", || {
		let status = world.rig.status()["status"].clone();
		(status["pid"] == json!(pid)).then_some(status)
	})
}

fn not_ready(world: &World) {
	let (said, ok) = world.rig.run("ready", json!({}));
	assert!(!ok, "a start still asking the session was ready: {said}");
}

/// A restart whose access is paused waits in its ask, and says so.
#[test]
fn a_start_asking_through_a_paused_access_reports_itself_paused_and_not_ready() {
	let world = World::new("bot-live-ask-paused");
	run_within(Duration::from_secs(90), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		killed_after_send(&world, &issued.link);
		grants.pause(&issued.name).await.unwrap();
		let mut again = world.rig.serve_stored_refused();
		status_of(&world, again.child.id());
		eventually("status to show paused", || (world.access() == "paused").then_some(()));
		assert_eq!(world.rig.status()["status"]["pid"], json!(again.child.id()));
		not_ready(&world);
		again.signal("-TERM");
		assert!(again.wait().success(), "the bot exited with a failure");
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A restart whose ask the session cannot answer waits in it, and its status
/// names this process with an access it does not know yet.
#[test]
fn a_start_whose_ask_the_session_cannot_answer_reports_itself_and_not_ready() {
	let world = World::new("bot-live-ask-unreachable");
	run_within(Duration::from_secs(90), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		killed_after_send(&world, &issued.link);
		let mut again = world.rig.serve_stored_at("holder-look@*");
		eventually("the receipt ask to meet its fault", || {
			world
				.rig
				.log()
				.lines()
				.any(|line| line.contains(words::TRYING_AGAIN) && line.contains("a fault made the ask fail"))
				.then_some(())
		});
		let status = status_of(&world, again.child.id());
		assert_eq!(status["access"], "unknown", "{status}");
		not_ready(&world);
		again.signal("-TERM");
		assert!(again.wait().success(), "the bot exited with a failure");
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A session that refuses the question for good ends the start with what
/// happened and the one next step, and never serves.
#[test]
fn a_start_the_session_refuses_to_answer_for_good_ends_with_its_next_step() {
	let world = World::new("bot-live-ask-refused");
	run_within(Duration::from_secs(90), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		killed_after_send(&world, &issued.link);
		let mut again = world.rig.serve_stored_at("holder-refused@*");
		assert!(!again.wait().success(), "a start the session refused went on");
		let said = world.rig.output();
		assert!(
			said.contains(words::ASK_REFUSED)
				&& said.contains(words::ASK_REFUSED_FAULT)
				&& said.contains(words::START_AGAIN),
			"{said}"
		);
		assert_eq!(
			said.matches("ROOMS-BOT-SERVING").count(),
			1,
			"the refused start served: {said}"
		);
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A restart whose access was revoked ends in its ask with the access error
/// and the command that gives the bot a new link, and never serves.
#[test]
fn a_start_asking_through_a_revoked_access_ends_with_the_command_for_a_new_link() {
	let world = World::new("bot-live-ask-revoked");
	run_within(Duration::from_secs(90), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		killed_after_send(&world, &issued.link);
		grants.revoke(&issued.name).await.unwrap();
		let mut again = world.rig.serve_stored_refused();
		assert!(!again.wait().success(), "a start with a revoked access went on");
		let said = world.rig.output();
		assert!(
			said.contains(r#""class":"access""#) && said.contains("--link - --replace-link"),
			"{said}"
		);
		assert_eq!(
			said.matches("ROOMS-BOT-SERVING").count(),
			1,
			"the revoked start served: {said}"
		);
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}
