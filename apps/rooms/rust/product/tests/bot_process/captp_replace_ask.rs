//! A replacement link against a real session when the stored link's access
//! left a line behind unsettled. The session keeps a line's receipt under the
//! access that sent it, so it is asked through the serving link, and its
//! answer, never a stored count, says whether the line is the serving
//! access's own or another's, which only its echo settles.
use super::captp::{DWELL, World, another_form, stored};
use super::captp_crashes::{answered, still_open};
use super::rig::eventually;
use super::session_rig::{assert_same_secret, run_within};
use super::words;
use rooms_application::content::session::custody::MAX_EFFECTS;
use rooms_services::session::attached::{EffectStatus, Holder};
use serde_json::json;
use std::time::Duration;

fn posted(world: &World, text: &str) -> usize {
	world
		.seen()
		.iter()
		.filter(|line| line.kind == "direct" && line.text == text)
		.count()
}

/// The access that sent a line is paused, so the replacement leaves it, and the
/// replacement link is the same access in another form. The ask through it
/// is refused while the access is paused, so nothing is stored and the ask is
/// tried again. Once the access resumes, the session says the line is this
/// access's own, so it settles it by its receipt and never by its echo.
#[test]
fn a_replacement_link_to_the_same_access_keeps_what_it_sent() {
	let world = World::new("bot-live-replace-ask-same");
	let text = "sent before the same access came back";
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		killed_at_link(&world, &issued.link, text);
		let before = stored(&world);
		grants.pause(&issued.name).await.unwrap();
		let again = another_form(&issued.link);
		let bot = world.rig.serve_replacing_unreported(&again, None);
		eventually(
			"the ask through the new link to fail while the access is paused",
			|| world.rig.log().contains(words::TRYING_AGAIN).then_some(()),
		);
		assert_same_secret(stored(&world), &before, "a link was stored before the session answered");
		grants.resume(&issued.name).await.unwrap();
		eventually("the replacement to be stored", || {
			(stored(&world) != before).then_some(())
		});
		assert_same_secret(
			stored(&world),
			format!("{again}\n"),
			"the stored link is not the replacement",
		);
		answered(&world, text);
		assert!(bot.stop().success());
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	std::thread::sleep(DWELL);
	assert_eq!(posted(&world, text), 1, "{:?}", world.seen());
	still_open(&world);
	let log = world.rig.log();
	assert!(
		!log.contains(words::NO_RECEIPT_HELD) && !log.contains(words::NOT_SENT_HERE),
		"the access's own line was left to its echo: {log}"
	);
	world.finish();
}

/// The access that sent the line is paused and the replacement is another
/// access. The session answers that another access sent it, which is not a
/// refusal to retry, so the link is stored and the line is decided by its
/// echo. The first ask is made to fail, and is asked again with nothing
/// stored between.
#[test]
fn a_replacement_link_to_another_access_decides_the_line_by_its_echo_after_a_failed_ask() {
	let world = World::new("bot-live-replace-ask-another");
	let text = "sent by the access that was left";
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let first = grants.issue("the first", &terms).await.unwrap();
		killed_at_link(&world, &first.link, text);
		let before = stored(&world);
		grants.pause(&first.name).await.unwrap();
		let second = grants.issue("the second", &terms).await.unwrap();
		let bot = world
			.rig
			.serve_replacing_unreported(&second.link, Some("holder-look@2"));
		eventually("the failed ask to be tried again", || {
			world.rig.log().contains(words::TRYING_AGAIN).then_some(())
		});
		assert_same_secret(stored(&world), &before, "a link was stored before the ask was answered");
		eventually("the replacement to be stored", || {
			(stored(&world) != before).then_some(())
		});
		assert_same_secret(
			stored(&world),
			format!("{}\n", second.link),
			"the second link is not the one stored",
		);
		answered(&world, text);
		assert!(bot.stop().success());
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	std::thread::sleep(DWELL);
	assert_eq!(posted(&world, text), 1, "{:?}", world.seen());
	still_open(&world);
	let log = world.rig.log();
	assert_eq!(
		log.matches(words::TRYING_AGAIN).count(),
		1,
		"another access's answer was retried: {log}"
	);
	assert!(
		log.contains(words::NO_RECEIPT_HELD) || log.contains(words::NOT_SENT_HERE),
		"{log}"
	);
	world.finish();
}

/// A replacement to another access stopped after its link was saved and before
/// the answers were applied leaves the new link serving, and the next plain
/// start asks again and finishes: the line is decided by its echo and posts
/// once.
#[test]
fn a_replacement_stopped_after_its_link_is_saved_is_finished_by_the_next_start() {
	let world = World::new("bot-live-replace-ask-after-link");
	let text = "sent before the stop after the save";
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let first = grants.issue("the first", &terms).await.unwrap();
		killed_at_link(&world, &first.link, text);
		grants.pause(&first.name).await.unwrap();
		let second = grants.issue("the second", &terms).await.unwrap();
		let mut cut = world.rig.serve_replacing_ended_at(&second.link, "after-link");
		assert!(!cut.wait().success(), "the replacement was not stopped after its link");
		assert_same_secret(
			stored(&world),
			format!("{}\n", second.link),
			"the second link is not the one stored",
		);
		let bot = world.serve();
		answered(&world, text);
		assert!(bot.stop().success());
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	std::thread::sleep(DWELL);
	assert_eq!(posted(&world, text), 1, "{:?}", world.seen());
	still_open(&world);
	let log = world.rig.log();
	assert!(
		log.contains(words::NO_RECEIPT_HELD) || log.contains(words::NOT_SENT_HERE),
		"{log}"
	);
	world.finish();
}

/// A line the first access sent is its own again once the stored link goes
/// back to it after a second, because the session answers by access: the
/// line is settled by its receipt and posts once.
#[test]
fn a_line_belongs_to_its_access_again_when_the_first_link_returns_after_a_second() {
	let world = World::new("bot-live-replace-ask-back");
	let text = "sent by the first access";
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let first = grants.issue("the first", &terms).await.unwrap();
		killed_at_link(&world, &first.link, text);
		grants.pause(&first.name).await.unwrap();
		let second = grants.issue("the second", &terms).await.unwrap();
		let mut cut = world.rig.serve_replacing_ended_at(&second.link, "after-link");
		assert!(!cut.wait().success(), "the replacement was not stopped after its link");
		grants.resume(&first.name).await.unwrap();
		let bot = world.rig.serve_replacing(&first.link);
		answered(&world, text);
		assert!(bot.stop().success());
		assert_same_secret(
			stored(&world),
			format!("{}\n", first.link),
			"the first link is not the one stored",
		);
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	std::thread::sleep(DWELL);
	assert_eq!(posted(&world, text), 1, "{:?}", world.seen());
	still_open(&world);
	let log = world.rig.log();
	assert!(
		!log.contains(words::NO_RECEIPT_HELD) && !log.contains(words::NOT_SENT_HERE),
		"the access's own line was left to its echo: {log}"
	);
	world.finish();
}

/// The bot serves `link` and is killed right after its send of `text`.
fn killed_at_link(world: &World, link: &str, text: &str) {
	let mut bot = world.rig.serve_linked_at(link, json!({}), Some("after-send"));
	world.dm(&format!("reply:{text}"));
	assert!(!bot.process.wait().success(), "the bot was not killed after its send");
}

/// A line the second access finished by its echo, while the first held its
/// receipt, stays recorded in the ledger as replaced. When the first link
/// returns, its access holds the receipt again, so it keeps it and the record
/// goes: the session holds no receipt of the operation afterward, and the
/// line posted once.
#[test]
fn a_receipt_a_second_link_could_not_keep_is_kept_when_the_first_link_returns() {
	let world = World::new("bot-live-replace-ask-replaced");
	let text = "sent by the first access, finished by the second";
	run_within(Duration::from_secs(180), async {
		let (issuer, grants, terms) = world.issuer().await;
		let first = grants.issue("the first", &terms).await.unwrap();
		let second = grants.issue("the second", &terms).await.unwrap();
		let watcher = grants.issue("the watcher", &terms).await.unwrap();
		killed_at_link(&world, &first.link, text);
		grants.pause(&first.name).await.unwrap();
		let bot = world.rig.serve_replacing(&second.link);
		answered(&world, text);
		assert!(bot.stop().success());
		let ledger = world.rig.ledger();
		let operation = ledger["replaced"][0]["operation"].as_str().unwrap().to_owned();
		assert_eq!(ledger["replaced"].as_array().unwrap().len(), 1, "{ledger}");
		let runtime = super::session_rig::host().await;
		let view = super::session_rig::attach(&runtime, &watcher.link).await;
		assert_eq!(
			view.holder(&operation).await.unwrap(),
			Holder::Another,
			"the first access's receipt is the leak the record exists for"
		);
		grants.resume(&first.name).await.unwrap();
		let bot = world.rig.serve_replacing(&first.link);
		eventually("the first access to keep its receipt", || {
			(world.rig.ledger()["replaced"].as_array().unwrap().is_empty()).then_some(())
		});
		// A kept receipt is adopted, which the session evicts when it needs the
		// place. One still waiting for its access holds its place for good, so
		// a watcher that leaves every place of the session unkept fits only
		// when the first access kept its own.
		let room = world.fixture.room_id(0);
		let mut filled = Vec::new();
		for round in 0..MAX_EFFECTS {
			let (operation, text) = (format!("fill-{round}"), format!("fills a place {round}"));
			let base = view.revision().await.unwrap();
			filled.push((operation.clone(), text.clone(), base));
			let status = view
				.say_at(&operation, base, &room, &text)
				.await
				.unwrap_or_else(|error| {
					panic!("the first access's receipt still holds a place of the session at round {round}: {error}")
				});
			assert_eq!(status, EffectStatus::Committed, "round {round}");
		}
		for (operation, text, base) in filled {
			view.release_line(&operation, base, &room, &text).await.unwrap();
		}
		assert!(bot.stop().success());
		drop(view);
		runtime.close(glowcap::PendingWork::Cancel).await.unwrap();
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	std::thread::sleep(DWELL);
	assert_eq!(posted(&world, text), 1, "{:?}", world.seen());
	still_open(&world);
	assert!(world.rig.log().contains(words::LINE_KEPT), "{}", world.rig.log());
	world.finish();
}
