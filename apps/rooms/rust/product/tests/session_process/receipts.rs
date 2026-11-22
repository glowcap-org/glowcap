//! What a session's receipts decide about a line sent again, and who frees a
//! receipt nobody kept, against real session processes.
use super::session_rig::{Fixture, attach, call, call_when_paced, host, run_within};
use super::*;
use glowcap::PendingWork;
use rooms_application::content::session::{Preset, Terms, custody::MAX_EFFECTS};
use rooms_platform::HostPlatform;
use rooms_services::session::attached::{EffectStatus, Error, Grants};
use serde_json::json;
use std::path::Path;

const ROOM: &str = "receipts-room";

/// How many lines reading `text` the member at `state` has seen, once it has
/// seen `marker`, a line sent after them.
fn posted(state: &Path, text: &str, marker: &str) -> usize {
	let deadline = Instant::now() + Duration::from_secs(10);
	loop {
		let batch = call(state, "tick", json!({"wait": ["0"]}));
		let texts: Vec<_> = batch["pending"]
			.as_array()
			.unwrap()
			.iter()
			.filter_map(|event| event["event"]["notice"]["text"].as_str())
			.collect();
		if texts.contains(&marker) {
			return texts.iter().filter(|seen| **seen == text).count();
		}
		assert!(Instant::now() < deadline, "{marker:?} never arrived");
		std::thread::sleep(Duration::from_millis(100));
	}
}

/// A receipt is the only fence against a second post. Released, the same
/// operation at the same base is admitted again and posts again, so a
/// sender that lost its receipt cannot resend and stay at one post.
#[test]
fn an_operation_sent_again_at_its_base_after_its_receipt_is_released_posts_again() {
	let fixture = Fixture::start("receipts-resend", &["receipts-one", "receipts-two"], ROOM);
	let (one, two) = (&fixture.peers[0], &fixture.peers[1]);
	let room = fixture.room_id(0);
	let text = "said twice under one operation";
	run_within(Duration::from_secs(60), async {
		let runtime = host().await;
		let view = attach(&runtime, &one.link).await;
		let base = view.revision().await.unwrap();
		let first = view.say_at("resend-1", base, &room, text).await.unwrap();
		assert_eq!(first, EffectStatus::Committed);
		view.release_line("resend-1", base, &room, text).await.unwrap();
		let again = view.say_at("resend-1", base, &room, text).await.unwrap();
		assert_eq!(again, EffectStatus::Committed, "the base fenced the resend");
		view.release_line("resend-1", base, &room, text).await.unwrap();
		view.say("resend-marker", &room, "after the resend").await.unwrap();
		drop(view);
		runtime.close(PendingWork::Cancel).await.unwrap();
	});
	assert_eq!(posted(&two.state, text, "after the resend"), 2);
	fixture.finish();
}

/// A committed line nobody kept holds a receipt place that only its own
/// access may free. Revoking that access frees it, so more accesses than the
/// session has receipt places can each leave one, and the owner still
/// commands.
#[test]
fn revoking_an_access_releases_the_receipts_it_left_unkept() {
	let fixture = Fixture::start("receipts-revoked", &["receipts-one", "receipts-two"], ROOM);
	let (one, two) = (&fixture.peers[0], &fixture.peers[1]);
	let management = std::fs::read_to_string(one.state.join("management.sturdyref")).unwrap();
	let room = fixture.room_id(0);
	let rounds = MAX_EFFECTS * 2;
	run_within(Duration::from_secs(120), async {
		let issuer = host().await;
		let grants = Grants::attach(&issuer, HostPlatform, &management).await.unwrap();
		let terms = Terms::new(Preset::Collaborator.values()).unwrap();
		for round in 0..rounds {
			let issued = grants.issue(&format!("left unkept {round}"), &terms).await.unwrap();
			let holder = host().await;
			let view = attach(&holder, &issued.link).await;
			let (operation, text) = (format!("unkept-{round}"), format!("left unkept {round}"));
			// The session releases a revoked access's receipts soon after the
			// revocation, so a send refused for a full window is tried again,
			// and so is one the session paces.
			let deadline = Instant::now() + Duration::from_secs(10);
			let waits = |error: &Error| {
				["receipts are full", "rate-limited"]
					.iter()
					.any(|why| error.to_string().contains(why))
			};
			loop {
				let base = view.revision().await.unwrap();
				match view.say_at(&operation, base, &room, &text).await {
					Ok(status) => {
						assert_eq!(status, EffectStatus::Committed, "round {round}");
						break;
					}
					Err(error) if waits(&error) && Instant::now() < deadline => {
						tokio::time::sleep(Duration::from_millis(200)).await;
					}
					Err(error) => panic!("round {round}: the revoked receipts were never released: {error}"),
				}
			}
			drop(view);
			holder.close(PendingWork::Cancel).await.unwrap();
			grants.revoke(&issued.name).await.unwrap();
		}
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	let owner = call_when_paced(
		&one.state,
		"reply",
		json!({"room": [ROOM], "text": ["the owner still commands"]}),
	);
	assert_eq!(owner["status"], "committed", "{owner}");
	for round in 0..rounds {
		assert_eq!(
			posted(&two.state, &format!("left unkept {round}"), "the owner still commands"),
			1,
			"round {round}"
		);
	}
	fixture.finish();
}
