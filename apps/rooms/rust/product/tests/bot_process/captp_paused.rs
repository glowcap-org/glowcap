//! A request whose executor the real session pauses, because its observation
//! expired. The session fault `expire-first-line-observation` or
//! `expire-first-open-observation` makes the first request of that kind after
//! the session restarts expire its observation at once, so the bot's receipt
//! reads unknown. The bot gives it back, the session retires the paused
//! executor with the receipt, and the receipt's place is free again. Each
//! proof serves the bot on the collaborator access an operator issues.
use super::captp::{FRIEND, World};
use super::captp_crashes::answered;
use super::captp_direct::{say, turn};
use super::rig::{Bot, eventually};
use super::session_rig::{free_places, run_within};
use super::words;
use glowcap::PendingWork;
use rooms_application::content::session::custody::MAX_EFFECTS;
use rooms_platform::HostPlatform;
use rooms_services::session::attached::Grants;
use serde_json::json;
use std::time::Duration;

const LINE: &str = "expire-first-line-observation";
const OPEN: &str = "expire-first-open-observation";

/// Issue the bot a collaborator access, restart its session armed with
/// `fault`, and serve the bot on that access. Answers the grants of a host
/// to close, issued after the restart.
pub(super) async fn paused(
	world: &mut World,
	fault: &str,
	bot_fault: Option<&str>,
) -> (glowcap::Runtime, Grants<HostPlatform>, Bot) {
	let (issuer, grants, terms) = world.issuer().await;
	let issued = grants.issue("the bot", &terms).await.unwrap();
	issuer.close(PendingWork::Cancel).await.unwrap();
	world.restart_in_room(fault);
	let (issuer, grants, _) = world.issuer().await;
	let bot = world.rig.serve_linked_at(&issued.link, json!({}), bot_fault);
	(issuer, grants, bot)
}

fn sending(world: &World) -> u64 {
	world.rig.status()["status"]["sending"].as_u64().unwrap()
}

/// Every receipt place is free once the bot has stopped: the paused line's
/// receipt was given back, and the bot keeps or releases every other.
async fn places_free(world: &World, grants: &Grants<HostPlatform>) {
	let room = world.fixture.room_id(0);
	assert_eq!(
		free_places(grants, &room, "filler", Duration::ZERO).await,
		MAX_EFFECTS,
		"a receipt still holds a place"
	);
}

#[test]
fn a_paused_line_is_given_back_and_the_next_message_is_answered() {
	let mut world = World::new("bot-paused-line");
	run_within(Duration::from_secs(90), async {
		let (issuer, grants, bot) = paused(&mut world, LINE, None).await;
		world.dm("reply:paused once");
		world.await_line("direct", "paused once");
		eventually("the lane to free", || (sending(&world) == 0).then_some(()));
		world.dm("reply:next");
		world.await_line("direct", "next");
		eventually("the next line to be kept", || (sending(&world) == 0).then_some(()));
		let (log, status) = (world.rig.log(), world.rig.status());
		assert!(bot.stop().success(), "the bot exited with a failure");
		// Only the paused executor leaves a posted line's receipt unknown, and
		// the bot keeps no unknown receipt: it is released whether or not
		// activity showed the line by the time the bot read it.
		assert!(
			log.contains(words::NOT_KEPT) || log.contains(words::CANNOT_SAY_WHETHER),
			"the fault never fired: {log}"
		);
		assert!(!log.contains(words::RECEIPT_LEFT), "{log}");
		assert_eq!(status["status"]["unreleased_lines"], 0, "{status}");
		assert_eq!(world.count("direct", "paused once"), 1);
		places_free(&world, &grants).await;
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

#[test]
fn a_paused_open_is_given_back_and_its_note_goes() {
	paused_open("bot-paused-open", None);
}

/// A given-back open whose note the bot fails to remove is never sent again:
/// the note stays given up, and the next look only gives the receipt back.
#[test]
fn a_given_back_open_whose_note_stays_is_never_sent_again() {
	let log = paused_open("bot-paused-open-forget", Some("forget@1"));
	assert!(
		log.contains(words::GIVEN_UP),
		"the second look sent the open again: {log}"
	);
}

/// Give a paused open back with the bot armed at `bot_fault`, and answer the
/// bot's log.
fn paused_open(label: &str, bot_fault: Option<&str>) -> String {
	let mut world = World::new(label);
	let mut seen = String::new();
	run_within(Duration::from_secs(90), async {
		let (issuer, grants, bot) = paused(&mut world, OPEN, bot_fault).await;
		turn(&world, &[say(FRIEND, "opened while paused")]);
		eventually("the open's receipt to be given back", || {
			world
				.rig
				.log()
				.contains("so the session gave its receipt back")
				.then_some(())
		});
		eventually("the notes to go", || {
			std::fs::read_dir(world.rig.dir.join("opens"))
				.map_or(true, |mut notes| notes.next().is_none())
				.then_some(())
		});
		eventually("the lane to free", || (sending(&world) == 0).then_some(()));
		// The next message in the room is answered, and its reply kept.
		world.room("@bot-host reply:next");
		world.await_line("room", "next");
		eventually("the next reply to be kept", || (sending(&world) == 0).then_some(()));
		let (log, status) = (world.rig.log(), world.rig.status());
		assert!(bot.stop().success(), "the bot exited with a failure");
		// Only the paused executor leaves an open unsettled.
		assert!(log.contains(words::DID_NOT_SETTLE), "the fault never fired: {log}");
		assert_eq!(status["status"]["unsettled_opens"], 0, "{status}");
		places_free(&world, &grants).await;
		issuer.close(PendingWork::Cancel).await.unwrap();
		seen = log;
	});
	world.finish();
	seen
}

/// A line the first access sent, whose executor the session pauses, is
/// finished by the second access's echo check and recorded as replaced.
/// When the first link returns, its access gives the receipt back and the
/// record goes.
#[test]
fn a_replaced_line_whose_executor_is_paused_is_given_back_and_its_record_goes() {
	let mut world = World::new("bot-paused-replaced");
	let text = "sent by the first access, paused";
	run_within(Duration::from_secs(180), async {
		let (issuer, grants, terms) = world.issuer().await;
		let first = grants.issue("the first", &terms).await.unwrap();
		let second = grants.issue("the second", &terms).await.unwrap();
		issuer.close(PendingWork::Cancel).await.unwrap();
		world.restart_in_room(LINE);
		let (issuer, grants, _) = world.issuer().await;
		let mut bot = world.rig.serve_linked_at(&first.link, json!({}), Some("after-send"));
		world.dm(&format!("reply:{text}"));
		assert!(!bot.process.wait().success(), "the bot was not killed after its send");
		grants.pause(&first.name).await.unwrap();
		let bot = world.rig.serve_replacing(&second.link);
		answered(&world, text);
		assert!(bot.stop().success());
		assert_eq!(world.rig.ledger()["replaced"].as_array().unwrap().len(), 1);
		grants.resume(&first.name).await.unwrap();
		let bot = world.rig.serve_replacing(&first.link);
		eventually("the first access to give its receipt back", || {
			world.rig.ledger()["replaced"]
				.as_array()
				.unwrap()
				.is_empty()
				.then_some(())
		});
		let log = world.rig.log();
		assert!(bot.stop().success());
		assert!(log.contains(words::LINE_RELEASED), "the fault never fired: {log}");
		assert!(!log.contains(words::RECEIPT_LEFT), "{log}");
		places_free(&world, &grants).await;
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	assert_eq!(world.count("direct", text), 1, "{:?}", world.seen());
	world.finish();
}

/// A line the first access sent, whose executor the session pauses, and whose
/// access is then revoked, so the session's sweep gives the receipt back. The
/// released receipt still answers for its sender, so the second access settles
/// the line by its echo alone and records it as replaced, and never sends it
/// again.
#[test]
fn a_revoked_accesss_paused_line_is_settled_by_its_echo_alone() {
	let mut world = World::new("bot-paused-revoked");
	let text = "sent by the revoked access, paused";
	run_within(Duration::from_secs(180), async {
		let (issuer, grants, terms) = world.issuer().await;
		let first = grants.issue("the first", &terms).await.unwrap();
		let second = grants.issue("the second", &terms).await.unwrap();
		issuer.close(PendingWork::Cancel).await.unwrap();
		world.restart_in_room(LINE);
		let (issuer, grants, _) = world.issuer().await;
		let mut bot = world.rig.serve_linked_at(&first.link, json!({}), Some("after-send"));
		world.dm(&format!("reply:{text}"));
		assert!(!bot.process.wait().success(), "the bot was not killed after its send");
		grants.revoke(&first.name).await.unwrap();
		let bot = world.rig.serve_replacing(&second.link);
		answered(&world, text);
		let ledger = world.rig.ledger();
		assert!(bot.stop().success());
		assert_eq!(ledger["replaced"].as_array().unwrap().len(), 1, "{ledger}");
		// The sweep gave the paused receipt back: filling every place evicts
		// it, which a receipt still unresolved would refuse.
		let room = world.fixture.room_id(0);
		assert_eq!(
			free_places(&grants, &room, "filler", Duration::from_secs(10)).await,
			MAX_EFFECTS,
			"the revoked access's paused receipt was never given back"
		);
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	assert_eq!(world.count("direct", text), 1, "{:?}", world.seen());
	world.finish();
}
