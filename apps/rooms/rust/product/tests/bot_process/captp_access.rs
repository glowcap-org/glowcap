//! The settings of a first start are stored before its link.
//! A start without them is refused and changes nothing it stored.
//! A revoked stored link names the command that replaces it.
use super::captp::World;
use super::session_rig::{assert_same_secret, run_within};
use super::words;
use serde_json::json;
use std::time::Duration;

/// A first start that ends after its settings are stored and before its link
/// is leaves a state the next start takes for a first start, which answers
/// its link and serves.
#[test]
fn a_first_start_ended_between_its_settings_and_its_link_starts_again_as_a_first_start() {
	let world = World::new("bot-live-between");
	run_within(Duration::from_secs(60), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		let mut ended = world.rig.serve_ended_at(&issued.link, "before-link");
		assert!(!ended.wait().success(), "the bot was not ended before its link");
		assert!(
			world.rig.dir.join("config.json").exists(),
			"the settings were not stored first"
		);
		assert!(
			!world.rig.dir.join("session.link").exists(),
			"the link was stored too early"
		);

		let bot = world.rig.serve_linked(&issued.link, json!({}));
		world.dm("reply:served after the stop");
		world.await_line("direct", "served after the stop");
		assert!(world.rig.dir.join("session.link").exists(), "the link was never stored");
		assert!(bot.stop().success(), "the bot exited with a failure");
		assert_eq!(world.count("direct", "served after the stop"), 1);
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A stored link whose settings are gone is never started over, replaced or
/// not: the start is refused, and the stored link, the ledger, and the missing
/// settings stay as they were.
#[test]
fn a_stored_link_without_its_settings_is_refused_whether_or_not_it_is_replaced() {
	let world = World::new("bot-live-no-settings");
	run_within(Duration::from_secs(60), async {
		let (issuer, grants, terms) = world.issuer().await;
		let first = grants.issue("the bot", &terms).await.unwrap();
		let second = grants.issue("the next bot", &terms).await.unwrap();
		let bot = world.rig.serve_linked(&first.link, json!({}));
		assert!(bot.stop().success(), "the bot exited with a failure");
		let stored = std::fs::read(world.rig.dir.join("session.link")).unwrap();
		std::fs::remove_file(world.rig.dir.join("config.json")).unwrap();

		let mut replaced = world.rig.serve_refused(&second.link, true);
		assert!(!replaced.wait().success(), "the replacement was not refused");
		assert!(
			world.rig.output().contains(words::CONFIG_MISSING),
			"{}",
			world.rig.output()
		);
		assert_same_secret(
			std::fs::read(world.rig.dir.join("session.link")).unwrap(),
			&stored,
			"a refused start changed the stored link",
		);

		let ledger = std::fs::read(world.rig.dir.join("turns.json")).ok();
		let mut plain = world.rig.serve_stored_refused();
		assert!(!plain.wait().success(), "a stored link without settings started over");
		let said = world.rig.output();
		assert!(said.contains(words::RESTORE_OR_START_FRESH), "{said}");
		assert!(
			!world.rig.dir.join("config.json").exists(),
			"the refused start stored settings"
		);
		assert_eq!(std::fs::read(world.rig.dir.join("turns.json")).ok(), ledger);
		assert_same_secret(
			std::fs::read(world.rig.dir.join("session.link")).unwrap(),
			&stored,
			"a refused start changed the stored link",
		);
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// The access is revoked while the bot is stopped. The restart dials the
/// stored link, which is not the first link, so it ends with the command that
/// replaces a stored link.
#[test]
fn a_session_that_revoked_the_stored_link_while_the_bot_was_stopped_ends_the_restart_naming_replace_link() {
	let world = World::new("bot-live-revoked-restart");
	run_within(Duration::from_secs(60), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		let bot = world.rig.serve_linked(&issued.link, json!({}));
		assert!(bot.stop().success(), "the bot exited with a failure");
		grants.revoke(&issued.name).await.unwrap();
		let mut restarted = world.rig.serve_stored_refused();
		assert!(
			!restarted.wait().success(),
			"a revoked stored link left the bot serving"
		);
		let said = world.rig.output();
		assert!(said.contains("--replace-link"), "{said}");
		assert!(!said.contains(words::LINK_NOT_ACCEPTED), "{said}");
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A first start has sent nothing, so a note left in `opens/` is an earlier
/// link's. It is refused with the same way out as a ledger of open turns, and
/// stores no settings or link.
#[test]
fn a_first_start_that_finds_an_earlier_links_open_notes_is_refused() {
	let world = World::new("bot-live-first-notes");
	run_within(Duration::from_secs(60), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		let opens = world.rig.dir.join("opens");
		std::fs::create_dir_all(&opens).unwrap();
		let body = json!({
			"base": 3,
			"introduction": {"directory": "d", "peer": "ann", "registration": "r"},
			"conversation": "c",
			"turn": 9999,
		});
		let note = opens.join(format!("{:032x}.json", 7));
		std::fs::write(&note, body.to_string()).unwrap();
		let mut first = world.rig.serve_refused(&issued.link, false);
		assert!(!first.wait().success(), "a first start adopted an earlier link's note");
		let said = world.rig.output();
		assert!(
			said.contains(words::OPENS_FROM_EARLIER_LINK) && said.contains(words::RESTORE_OR_START_FRESH),
			"{said}"
		);
		for file in ["session.link", "config.json"] {
			assert!(!world.rig.dir.join(file).exists(), "the refused start stored {file}");
		}
		assert_eq!(std::fs::read(&note).unwrap(), body.to_string().into_bytes());
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}
