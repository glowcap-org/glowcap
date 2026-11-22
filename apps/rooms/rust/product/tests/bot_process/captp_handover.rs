//! A bot's link replaced while a line it sent is still unsettled, against a
//! real session. Every case ends with the reply posted exactly once, no
//! failure line, and a session that still takes commands.
use super::captp::{DWELL, World};
use super::captp_crashes::{answered, killed_at, once_and_still_open, still_open};
use super::session_rig::{host, run_within};
use rooms_application::content::session::{Preset, Terms, custody::MAX_EFFECTS};
use rooms_platform::HostPlatform;
use rooms_services::session::attached::Grants;
use serde_json::json;
use std::time::Duration;

/// One round more than the session holds receipts for.
const ROUNDS: usize = MAX_EFFECTS + 1;

/// The old access, still live, keeps each line it sent before the new link
/// serves, so rounds past the session's receipt places still leave the
/// session taking commands.
#[test]
fn replies_sent_under_replaced_links_are_kept_by_the_old_access_and_post_once() {
	let world = World::new("bot-live-replace");
	let management = std::fs::read_to_string(world.fixture.peers[0].state.join("management.sturdyref")).unwrap();
	run_within(Duration::from_secs(240), async {
		let issuer = host().await;
		let grants = Grants::attach(&issuer, HostPlatform, &management).await.unwrap();
		let terms = Terms::new(Preset::Collaborator.values()).unwrap();
		let mut old = None;
		for round in 0..ROUNDS {
			let text = format!("before link {round}");
			killed_at(&world, "after-send", &text);
			let issued = grants.issue(&format!("the bot {round}"), &terms).await.unwrap();
			let bot = world.rig.serve_replacing(&issued.link);
			answered(&world, &text);
			assert!(bot.stop().success(), "round {round}: the bot exited with a failure");
			if let Some(name) = old.replace(issued.name) {
				grants.revoke(&name).await.unwrap();
			}
		}
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	std::thread::sleep(DWELL);
	let texts: Vec<String> = (0..ROUNDS).map(|round| format!("before link {round}")).collect();
	once_and_still_open(&world, &texts.iter().map(String::as_str).collect::<Vec<_>>());
	world.fixture.finish();
}

/// An old access revoked before the hand-over cannot settle the line it
/// sent, so the new link decides that line by its echo alone, never sends it
/// again, and never replaces it with a failure line. The session releases
/// the receipt the revoked access left, so more hand-overs than the session
/// has receipt places leave it taking its owner's command.
#[test]
fn a_line_a_revoked_link_sent_is_left_to_the_new_link_and_posts_once() {
	let world = World::new("bot-live-handed");
	let management = std::fs::read_to_string(world.fixture.peers[0].state.join("management.sturdyref")).unwrap();
	let text = |round: usize| format!("sent by link {round}");
	run_within(Duration::from_secs(400), async {
		let issuer = host().await;
		let grants = Grants::attach(&issuer, HostPlatform, &management).await.unwrap();
		let terms = Terms::new(Preset::Collaborator.values()).unwrap();
		let mut link = grants.issue("the bot 0", &terms).await.unwrap();
		for round in 0..MAX_EFFECTS {
			let mut bot = world.rig.serve_linked_at(&link.link, json!({}), Some("after-send"));
			world.dm(&format!("reply:{}", text(round)));
			assert!(
				!bot.process.wait().success(),
				"round {round}: the bot was not killed after its send"
			);
			grants.revoke(&link.name).await.unwrap();
			link = grants.issue(&format!("the bot {}", round + 1), &terms).await.unwrap();
			let bot = world.rig.serve_replacing(&link.link);
			answered(&world, &text(round));
			assert!(bot.stop().success(), "round {round}: the bot exited with a failure");
		}
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	std::thread::sleep(DWELL);
	let seen = world.seen();
	for round in 0..MAX_EFFECTS {
		let posted = seen
			.iter()
			.filter(|line| line.kind == "direct" && line.text == text(round))
			.count();
		assert_eq!(posted, 1, "{}: {seen:?}", text(round));
	}
	assert!(
		!seen.iter().any(|line| line.text.starts_with("I could not answer that")),
		"a failure line was posted: {seen:?}"
	);
	still_open(&world);
	let log = world.rig.log();
	assert!(log.contains("The new link decides it by its echo"), "{log}");
	assert!(
		!log.contains("holds no receipt for operation"),
		"the line was sent again: {log}"
	);
	world.fixture.finish();
}
