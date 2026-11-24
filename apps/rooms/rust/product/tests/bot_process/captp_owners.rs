//! The serving loop's list of held receipts against a real session: it
//! leaves alone every operation another owner settles, and an action's claim
//! is the owner its verb writes before the request leaves.
use super::captp::{World, action};
use super::captp_direct::{output, turn};
use super::captp_notes::kept_note;
use super::rig::eventually;
use super::session_rig::{free_places, run_within};
use super::words;
use rooms_application::content::session::custody::MAX_EFFECTS;
use serde_json::{Value, json};
use std::time::Duration;

/// A turn that only reads, so its end lists the held receipts.
fn read() -> Value {
	action("workspace", json!({}), &[])
}

/// Write a claim of a turn that has ended under `operation` while the bot
/// serves, run a turn so the list that follows its end meets the claim, and
/// wait for that list to remove it. The removal's log line is the proof that
/// a list answered and read its owners.
pub(super) fn listed_once_more(world: &World, operation: &str) {
	let removed = format!("{} was left by a turn whose agent stopped", words::action(operation));
	let before = world.rig.log().matches(&removed).count();
	let held = world.rig.dir.join("turn-actions");
	std::fs::create_dir_all(&held).unwrap();
	std::fs::write(
		held.join(format!("{operation}.json")),
		json!({"turn": 0, "what": {"say": {"to": "here"}}, "outcome": null}).to_string(),
	)
	.unwrap();
	assert_eq!(turn(world, &[read()]), "exit=0");
	eventually("a list to meet the planted claim", || {
		(world.rig.log().matches(&removed).count() > before).then_some(())
	});
}

/// An open whose look stays pending keeps its note, and the session holds its
/// committed receipt, so every list in that time names it. The list leaves it
/// to the look: no line about it as an action, through two lists. Once the
/// look may ask, it settles the open, and no place stays held.
#[test]
fn the_list_leaves_an_open_to_its_note() {
	let world = World::new("bot-live-list-owners");
	run_within(Duration::from_secs(150), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		let note = kept_note(&world, &issued.link);
		let operation = note.trim_end_matches(".json").to_owned();
		let bot = world.serve_at(Some("settle-pending@*"));
		// The second list starts only after the first has finished, so both
		// ran while the note held the open.
		listed_once_more(&world, &format!("{:032x}", 0x1157));
		listed_once_more(&world, &format!("{:032x}", 0x1158));
		let log = world.rig.log();
		assert!(
			!log.contains(&words::action(&operation)),
			"the list settled an open its note owns: {log}"
		);
		assert!(
			world.rig.dir.join("opens").join(&note).exists(),
			"the open's note went while its look was held pending"
		);
		world.stopped(bot);
		let bot = world.serve();
		eventually("the look to settle the open", || {
			(!world.rig.dir.join("opens").join(&note).exists()).then_some(())
		});
		eventually("the lane to free", || {
			(world.rig.status()["status"]["sending"] == 0).then_some(())
		});
		world.stopped(bot);
		assert!(
			!world.rig.log().contains(&words::action(&operation)),
			"the list settled the open as an action"
		);
		let room = world.fixture.room_id(0);
		assert_eq!(
			free_places(&grants, &room, "filler", Duration::ZERO).await,
			MAX_EFFECTS,
			"the open's receipt still holds a place"
		);
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// A `say` whose claim cannot be written is refused before its request
/// leaves: the verb fails as storage, no claim is left, the line never
/// posts, and the session holds no receipt for it.
#[test]
fn an_unwritable_claim_sends_nothing() {
	use std::os::unix::fs::PermissionsExt;
	const TEXT: &str = "never claimed";
	let world = World::new("bot-live-claim-unwritable");
	run_within(Duration::from_secs(120), async {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the bot", &terms).await.unwrap();
		let bot = world.rig.serve_linked(&issued.link, json!({}));
		let held = world.rig.dir.join("turn-actions");
		std::fs::create_dir_all(&held).unwrap();
		std::fs::set_permissions(&held, std::fs::Permissions::from_mode(0o500)).unwrap();
		let probe = held.join("probe");
		assert!(
			std::fs::write(&probe, "").is_err(),
			"the claims directory is writable, so the refusal cannot be shown"
		);
		assert_ne!(turn(&world, &[action("say", json!({"text": [TEXT]}), &[])]), "exit=0");
		let said = output(&world, 0);
		assert_eq!(said["error"]["class"], "storage", "{said}");
		std::fs::set_permissions(&held, std::fs::Permissions::from_mode(0o700)).unwrap();
		assert_eq!(std::fs::read_dir(&held).unwrap().count(), 0, "a claim was left");
		eventually("the lane to free", || {
			(world.rig.status()["status"]["sending"] == 0).then_some(())
		});
		world.stopped(bot);
		assert_eq!(world.count("room", TEXT), 0, "an unclaimed say posted");
		let room = world.fixture.room_id(0);
		assert_eq!(
			free_places(&grants, &room, "filler", Duration::ZERO).await,
			MAX_EFFECTS,
			"an unclaimed say holds a place"
		);
		issuer.close(glowcap::PendingWork::Cancel).await.unwrap();
	});
	world.finish();
}

/// The claim is on disk before the request leaves: a verb killed between the
/// two leaves the claim naming its operation, and the line has not posted.
#[test]
fn a_claim_is_written_before_its_request_leaves() {
	const TEXT: &str = "claimed first";
	let world = World::new("bot-live-claim-first");
	let bot = world.serve_at(Some("after-note"));
	turn(&world, &[action("say", json!({"text": [TEXT]}), &[])]);
	let operation = eventually("the loop to remove the killed verb's claim", || {
		let log = world.rig.log();
		let line = log
			.lines()
			.find(|line| line.contains("was left by a turn whose agent stopped"))?;
		Some(line.split("operation ").nth(1)?.split(' ').next()?.to_owned())
	});
	assert_eq!(operation.len(), 32, "the claim named no operation: {operation}");
	world.stopped(bot);
	assert_eq!(
		world.count("room", TEXT),
		0,
		"the line posted though its verb died before sending"
	);
	world.finish();
}
