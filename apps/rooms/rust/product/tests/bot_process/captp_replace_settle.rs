//! A bot's link replaced while a line it sent is still unsettled, or a
//! replacement stopped part way, against a real session. A case that sent a
//! reply ends with it posted exactly once, no failure line, and a session that
//! still takes commands.
use super::captp::{DWELL, World};
use super::captp_crashes::{answered, killed_at, once_and_still_open, still_open};
use super::session_rig::{assert_same_secret, run_within};
use super::words;
use rooms_application::content::session::custody::MAX_EFFECTS;
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
	run_within(Duration::from_secs(240), async {
		let (issuer, grants, terms) = world.issuer().await;
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
	world.finish();
}

/// An old access revoked before the replacement cannot settle the line it
/// sent, so the new link decides that line by its echo alone, never sends it
/// again, and never replaces it with a failure line. The session releases
/// the receipt the revoked access left, so more replacements than the session
/// has receipt places leave it taking its owner's command.
#[test]
fn a_line_a_revoked_link_sent_is_left_to_the_new_link_and_posts_once() {
	let world = World::new("bot-live-replace-settle");
	let text = |round: usize| format!("sent by link {round}");
	run_within(Duration::from_secs(400), async {
		let (issuer, grants, terms) = world.issuer().await;
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
		!seen.iter().any(|line| line.text.starts_with(words::COULD_NOT_ANSWER)),
		"a failure line was posted: {seen:?}"
	);
	still_open(&world);
	let log = world.rig.log();
	assert!(log.contains(words::MOVED_ON), "{log}");
	assert!(!log.contains(words::NO_RECEIPT), "the line was sent again: {log}");
	world.finish();
}

/// A replacement stopped after the old access settled its lines and before the
/// new link is saved leaves the old link serving and every note where it was.
/// Starting plain does not send the line again, and the old access, asked by
/// the session, finds it holds nothing for the two hand-written notes and
/// drops them. Running the same replacement again completes.
#[test]
fn a_replacement_stopped_before_its_link_is_saved_leaves_the_old_link_and_completes_when_repeated() {
	let world = World::new("bot-live-replace-stopped");
	let text = "sent before the stop";
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		killed_at(&world, "after-send", text);
		let old = std::fs::read(world.rig.dir.join("session.link")).unwrap();
		let opens = world.rig.dir.join("opens");
		std::fs::create_dir_all(&opens).unwrap();
		let given_up = json!({
			"base": 3,
			"introduction": {"directory": "d", "peer": "ann", "registration": "r"},
			"conversation": "c",
			"turn": 9999,
		});
		std::fs::write(opens.join(format!("{:032x}.json.unsettled", 4)), given_up.to_string()).unwrap();
		std::fs::write(opens.join(format!("{:032x}.json", 5)), given_up.to_string()).unwrap();
		let issued = grants.issue("the replacement", &terms).await.unwrap();
		let mut cut = world.rig.serve_replacing_ended_at(&issued.link, "before-link");
		assert!(!cut.wait().success(), "the replacement was not stopped before its link");
		assert!(
			opens.join(format!("{:032x}.json", 5)).exists(),
			"the stopped replacement's last look decided an open it could not settle"
		);
		assert_same_secret(
			std::fs::read(world.rig.dir.join("session.link")).unwrap(),
			&old,
			"a stopped replacement stored its link",
		);
		let plain = world.serve_at(None);
		super::rig::eventually("the old access to drop the notes the session holds nothing for", || {
			(std::fs::read_dir(&opens).unwrap().count() == 0).then_some(())
		});
		let log = world.rig.log();
		assert_eq!(log.matches(words::HOLDS_NOTHING).count(), 2, "{log}");
		assert!(plain.stop().success(), "the old link did not serve again");
		let bot = world.rig.serve_replacing(&issued.link);
		answered(&world, text);
		assert!(bot.stop().success(), "the repeated replacement failed");
		// Compared without printing, because both are links.
		assert!(
			std::fs::read(world.rig.dir.join("session.link")).unwrap() != old,
			"the repeated replacement did not store the new link"
		);
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	std::thread::sleep(DWELL);
	once_and_still_open(&world, &[text]);
	world.finish();
}

/// A line the old access could not settle, because its access was revoked
/// first, is left exactly as the old access recorded it by a replacement that
/// stops before its link is saved: the ledger bytes do not change, so nothing
/// of the replacement is committed ahead of the link. The repeated replacement
/// then decides the line by its echo, and it posts once.
#[test]
fn a_replacement_stopped_with_a_line_left_over_leaves_the_old_link_stored_and_the_repeat_posts_it_once() {
	let world = World::new("bot-live-replace-left");
	let text = "sent by the revoked link";
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let first = grants.issue("the first", &terms).await.unwrap();
		let mut bot = world.rig.serve_linked_at(&first.link, json!({}), Some("after-send"));
		world.dm(&format!("reply:{text}"));
		assert!(!bot.process.wait().success(), "the bot was not killed after its send");
		grants.revoke(&first.name).await.unwrap();
		let issued = grants.issue("the replacement", &terms).await.unwrap();
		let state = |file: &str| std::fs::read(world.rig.dir.join(file)).unwrap();
		let before = (state("turns.json"), state("session.link"));
		let mut cut = world.rig.serve_replacing_ended_at(&issued.link, "before-link");
		assert!(!cut.wait().success(), "the replacement was not stopped before its link");
		let after = (state("turns.json"), state("session.link"));
		// Compared without printing, because the stored link is one of them.
		assert!(
			after == before,
			"a replacement that never stored its link changed the old access's state"
		);
		let bot = world.rig.serve_replacing(&issued.link);
		answered(&world, text);
		assert!(bot.stop().success());
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	std::thread::sleep(DWELL);
	let seen = world.seen();
	let posted = seen.iter().filter(|line| line.kind == "direct" && line.text == text);
	assert_eq!(posted.count(), 1, "{seen:?}");
	assert!(
		!seen.iter().any(|line| line.text.starts_with(words::COULD_NOT_ANSWER)),
		"{seen:?}"
	);
	still_open(&world);
	let log = world.rig.log();
	assert!(log.contains(words::MOVED_ON), "{log}");
	world.finish();
}

/// A note the session says no access holds a receipt for is dropped by a good
/// replacement and never looked at: a look under the new access would ask the
/// session to start the open again. The fault answers every look at a note as
/// still pending, the way a session still running the open does, so a look
/// would show in the log. The note is written by hand, as the refused case
/// does, so the session holds nothing for it.
#[test]
fn a_note_the_session_holds_nothing_for_is_dropped_at_a_replacement_and_never_looked_at() {
	let world = World::new("bot-live-replace-pending");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let first = grants.issue("the first", &terms).await.unwrap();
		let bot = world.rig.serve_linked(&first.link, json!({}));
		assert!(bot.stop().success());
		let opens = world.rig.dir.join("opens");
		std::fs::create_dir_all(&opens).unwrap();
		let name = format!("{:032x}", 9);
		let body = json!({
			"base": 3,
			"introduction": {"directory": "d", "peer": "ann", "registration": "r"},
			"conversation": "c",
			"turn": 9999,
		});
		std::fs::write(opens.join(format!("{name}.json")), body.to_string()).unwrap();
		let issued = grants.issue("the replacement", &terms).await.unwrap();
		let bot = world.rig.serve_replacing_at(&issued.link, "settle-pending@*");
		super::rig::eventually("the note the session holds nothing for to be dropped", || {
			(std::fs::read_dir(&opens).unwrap().count() == 0).then_some(())
		});
		let status = world.rig.status();
		assert_eq!(
			(
				status["status"]["unsettled_opens"].clone(),
				status["status"]["replaced_opens"].clone()
			),
			(json!(0), json!(0)),
			"{status}"
		);
		assert!(bot.stop().success());
		let log = world.rig.log();
		assert!(log.contains(words::HOLDS_NOTHING), "{log}");
		assert!(
			!log.contains(words::DID_NOT_SETTLE)
				&& !log.contains(words::KEPT_ROUTE)
				&& !log.contains(words::STILL_SETTLING),
			"a look decided the note: {log}"
		);
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A turn still running when the old bot was killed starts again only once the
/// replacement link is saved. Until then the stored link is the old one, and
/// a verb the turn ran would attach with it. The fault fails the first save,
/// so the log must show the failure, the save working on the retry, and only
/// then the turn starting.
#[test]
fn a_running_turn_starts_under_a_replacement_only_after_its_link_is_saved() {
	let world = World::new("bot-live-replace-running");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let first = grants.issue("the first", &terms).await.unwrap();
		let mut bot = world.rig.serve_linked(&first.link, json!({}));
		world.dm("wait-file:never released");
		super::rig::eventually("the turn to start", || {
			world.rig.log().contains(words::TURN_STARTED).then_some(())
		});
		bot.kill();
		drop(bot);
		let issued = grants.issue("the replacement", &terms).await.unwrap();
		let bot = world.rig.serve_replacing_at(&issued.link, "link-write");
		super::rig::eventually("the turn to start under the replacement", || {
			(world.rig.log().matches(words::TURN_STARTED).count() == 2).then_some(())
		});
		let log = world.rig.log();
		let at = |what: &str| log.find(what).unwrap_or_else(|| panic!("no `{what}` in {log}"));
		let failed = at(&format!("{} {}", words::SAVING_LINK, words::TRYING_AGAIN));
		let saved = at(words::SAVED_ON_RETRY);
		let started = log.rfind(words::TURN_STARTED).unwrap();
		assert!(failed < saved, "{log}");
		assert!(saved < started, "the turn started before the link was saved: {log}");
		assert!(bot.stop().success());
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}
