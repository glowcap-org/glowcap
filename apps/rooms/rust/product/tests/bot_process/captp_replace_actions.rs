//! A pending action the old access could not settle before a new link
//! replaced it keeps its place, and `status` counts it. A replacement whose
//! old access cannot list its actions stores nothing, unless that access is
//! paused, and then `status` says it went unlisted once the new link is
//! stored.
use super::captp::{World, stored};
use super::captp_action_receipts::{notes, pending_say, stopped};
use super::rig::eventually;
use super::session_rig::{free_places, run_within};
use super::words;
use glowcap::PendingWork;
use rooms_application::content::session::custody::MAX_EFFECTS;
use serde_json::{Value, json};
use std::time::Duration;

/// A pending `say` the first access sent, which its last list before a
/// second access serves cannot settle, is recorded in the ledger. `status`
/// counts it, across a restart too, and its receipt still holds one of the
/// session's places, which only the first access, or its revocation, gives
/// back.
#[test]
fn an_action_the_old_access_could_not_settle_is_counted_as_replaced_while_its_receipt_holds_a_place() {
	let world = World::new("bot-live-action-replaced");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let first = grants.issue("the first", &terms).await.unwrap();
		let (bot, said) = pending_say(&world, &first.link, "said before the replacement");
		assert_eq!(said["status"], "pending", "{said}");
		stopped(&world, bot);
		let second = grants.issue("the second", &terms).await.unwrap();
		let bot = world.rig.serve_replacing_at(&second.link, "settle-pending@*");
		eventually("status to count the action as replaced", || {
			(world.rig.status()["status"]["replaced_actions"] == 1).then_some(())
		});
		let status = world.rig.status();
		assert_eq!(status["status"]["unsettled_actions"], 0, "{status}");
		eventually("the loop to record that it cannot say what the action did", || {
			notes(&world).is_empty().then_some(())
		});
		stopped(&world, bot);
		let bot = world.rig.serve_linked_at("", json!({}), None);
		eventually("the restart to count the action as replaced", || {
			(world.rig.status()["status"]["replaced_actions"] == 1).then_some(())
		});
		stopped(&world, bot);
		let room = world.fixture.room_id(0);
		assert_eq!(
			free_places(&grants, &room, "filler", Duration::ZERO).await,
			MAX_EFFECTS - 1,
			"the replaced action's receipt holds no place"
		);
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// The old access's list is the only record of its agent's actions, so it is
/// part of the replacement. The fault `held-list` makes that list fail as an
/// unreachable session does: the replacement exits with the list's failure
/// and the old link stays stored. Running the same replacement again lists
/// the pending action and records it.
#[test]
fn a_replacement_whose_old_access_cannot_list_its_actions_stores_nothing_and_the_repeat_records_them() {
	let world = World::new("bot-live-action-unlisted");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let first = grants.issue("the first", &terms).await.unwrap();
		let (bot, said) = pending_say(&world, &first.link, "said before a refused replacement");
		assert_eq!(said["status"], "pending", "{said}");
		stopped(&world, bot);
		let before = stored(&world);
		let second = grants.issue("the second", &terms).await.unwrap();
		let mut refused = world.rig.serve_replacing_ended_at(&second.link, "held-list@1");
		assert!(!refused.wait().success(), "the replacement went on without the list");
		assert!(stored(&world) == before, "the refused replacement stored its link");
		let output = world.rig.output();
		assert!(output.contains(words::OLD_UNLISTED), "{output}");
		let bot = world.rig.serve_replacing_at(&second.link, "settle-pending@*");
		eventually("status to count the action as replaced", || {
			(world.rig.status()["status"]["replaced_actions"] == 1).then_some(())
		});
		assert!(
			stored(&world) == format!("{}\n", second.link),
			"the repeated replacement did not store its link"
		);
		stopped(&world, bot);
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A paused first access cannot list the pending `say` it holds, and the bot
/// leaves a pause to its operator, so the replacement goes on. `status` says
/// the old access went unlisted, across a restart too, while the receipt
/// still holds one of the session's places.
#[test]
fn a_replacement_of_a_paused_access_goes_on_and_status_says_its_actions_went_unlisted() {
	let world = World::new("bot-live-action-paused");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let first = grants.issue("the first", &terms).await.unwrap();
		let (bot, said) = pending_say(&world, &first.link, "said before a pause");
		assert_eq!(said["status"], "pending", "{said}");
		stopped(&world, bot);
		grants.pause(&first.name).await.unwrap();
		let second = grants.issue("the second", &terms).await.unwrap();
		let bot = world.rig.serve_replacing_at(&second.link, "settle-pending@*");
		let status = world.rig.status();
		assert_eq!(status["status"]["replaced_unlisted"], "paused", "{status}");
		assert_eq!(status["status"]["replaced_actions"], 0, "{status}");
		assert!(
			stored(&world) == format!("{}\n", second.link),
			"the replacement did not store its link"
		);
		stopped(&world, bot);
		let bot = world.rig.serve_linked_at("", json!({}), None);
		let status = world.rig.status();
		assert_eq!(status["status"]["replaced_unlisted"], "paused", "{status}");
		stopped(&world, bot);
		let room = world.fixture.room_id(0);
		assert_eq!(
			free_places(&grants, &room, "filler", Duration::ZERO).await,
			MAX_EFFECTS - 1,
			"the unlisted action's receipt holds no place"
		);
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A replacement of a paused access whose new link the session refuses
/// stores neither the link nor why the old access went unlisted, so once the
/// operator resumes that access it serves with no such record.
#[test]
fn a_refused_replacement_of_a_paused_access_leaves_no_unlisted_record() {
	let world = World::new("bot-live-action-paused-refused");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let first = grants.issue("the first", &terms).await.unwrap();
		let (bot, said) = pending_say(&world, &first.link, "said before a pause");
		assert_eq!(said["status"], "pending", "{said}");
		stopped(&world, bot);
		grants.pause(&first.name).await.unwrap();
		let second = grants.issue("the second", &terms).await.unwrap();
		grants.revoke(&second.name).await.unwrap();
		let before = stored(&world);
		let mut refused = world.rig.serve_refused(&second.link, true);
		assert!(!refused.wait().success(), "the session served a revoked link");
		assert!(stored(&world) == before, "the refused replacement stored its link");
		let log = world.rig.log();
		assert!(log.contains("the old access is paused"), "{log}");
		grants.resume(&first.name).await.unwrap();
		let bot = world.rig.serve_linked_at("", json!({}), None);
		let status = world.rig.status();
		assert_eq!(status["status"]["replaced_unlisted"], Value::Null, "{status}");
		stopped(&world, bot);
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}
