//! What a session's receipts decide about a line sent again, and who frees a
//! receipt nobody kept, against real session processes.
use super::receipts_late::second_client;
use super::session_rig::{Fixture, attach, call, call_when_paced, free_places, free_port, host, run_within};
use super::*;
use glowcap::PendingWork;
use rooms_application::content::session::{Preset, Terms, custody::MAX_EFFECTS};
use rooms_platform::HostPlatform;
use rooms_services::session::attached::{
	EffectStatus, Error, GiveBack, Grants, Holder, Opened, Reach, Release, View, forfeit_reached,
};
use serde_json::json;
use std::path::Path;

pub(super) const ROOM: &str = "receipts-room";

/// How many lines reading `text` the member at `state` has seen, once it has
/// seen `marker`, a line sent after them.
pub(super) fn posted(state: &Path, text: &str, marker: &str) -> usize {
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

/// A released receipt still answers for its operation until newer receipts
/// push it out, so the same operation sent again at the same base is
/// answered from it and posts nothing, and a second release changes nothing.
#[test]
fn an_operation_sent_again_after_its_receipt_is_released_is_answered_from_it() {
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
		assert_eq!(
			view.release_line("resend-1", base, &room, text).await.unwrap(),
			Release::Released
		);
		let again = view.say_at("resend-1", base, &room, text).await.unwrap();
		assert_eq!(
			again,
			EffectStatus::Committed,
			"the released receipt answered the resend"
		);
		assert_eq!(
			view.release_line("resend-1", base, &room, text).await.unwrap(),
			Release::Released
		);
		// The second release left the receipt as it was: it still answers.
		assert_eq!(
			view.say_at("resend-1", base, &room, text).await.unwrap(),
			EffectStatus::Committed,
			"the second release changed the receipt"
		);
		view.say("resend-marker", &room, "after the resend").await.unwrap();
		drop(view);
		runtime.close(PendingWork::Cancel).await.unwrap();
	});
	assert_eq!(posted(&two.state, text, "after the resend"), 1);
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
				use rooms_application::failure::FailureCode;
				matches!(error, Error::Peer(cause)
					if matches!(cause.failure_code(), Some(FailureCode::ReceiptsFull | FailureCode::RateLimited)))
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

/// A receipt its access adopted is terminal, and the replay window keeps it
/// until newer receipts push it out, even after its access is revoked. Every
/// other access is told `another` until then, and `nobody` after.
#[test]
fn a_revoked_accesss_adopted_receipt_is_anothers_until_newer_receipts_push_it_out() {
	let fixture = Fixture::start("receipts-adopted", &["receipts-one", "receipts-two"], ROOM);
	let one = &fixture.peers[0];
	let management = std::fs::read_to_string(one.state.join("management.sturdyref")).unwrap();
	let room = fixture.room_id(0);
	run_within(Duration::from_secs(60), async {
		let issuer = host().await;
		let grants = Grants::attach(&issuer, HostPlatform, &management).await.unwrap();
		let terms = Terms::new(Preset::Collaborator.values()).unwrap();
		let (sender, asker) = (
			grants.issue("adopted sender", &terms).await.unwrap(),
			grants.issue("adopted asker", &terms).await.unwrap(),
		);
		let (sending, asking) = (host().await, host().await);
		let (sent, asked) = (attach(&sending, &sender.link).await, attach(&asking, &asker.link).await);
		let (operation, text) = ("adopted-1", "kept by its sender");
		let base = sent.revision().await.unwrap();
		assert_eq!(
			sent.say_at(operation, base, &room, text).await.unwrap(),
			EffectStatus::Committed
		);
		sent.keep_line(operation, base, &room, text).await.unwrap();
		assert_eq!(asked.holder(operation).await.unwrap(), Holder::Another);
		assert_eq!(
			sent.holder(operation).await.unwrap(),
			Holder::Mine,
			"the access that sent and adopted a receipt is still its holder"
		);
		drop(sent);
		sending.close(PendingWork::Cancel).await.unwrap();
		grants.revoke(&sender.name).await.unwrap();
		// The asker's own line is a session change, which wakes the sweep of
		// the revoked access's receipts.
		let after = asked.revision().await.unwrap();
		asked
			.say_at("adopted-after", after, &room, "after the revoke")
			.await
			.unwrap();
		asked
			.release_line("adopted-after", after, &room, "after the revoke")
			.await
			.unwrap();
		assert_eq!(
			asked.holder(operation).await.unwrap(),
			Holder::Another,
			"a revoked access's adopted receipt still answers for its operation"
		);
		assert_eq!(
			free_places(&grants, &room, "filler", Duration::ZERO).await,
			MAX_EFFECTS,
			"filling every place pushes the adopted receipt out"
		);
		assert_eq!(asked.holder(operation).await.unwrap(), Holder::Nobody);
		drop(asked);
		asking.close(PendingWork::Cancel).await.unwrap();
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	fixture.finish();
}

/// A line its access kept is the workspace's: giving its receipt back changes
/// nothing and answers kept, every time, and the receipt holds no place.
#[test]
fn giving_back_a_kept_lines_receipt_answers_kept_and_changes_nothing() {
	let fixture = Fixture::start("receipts-kept-line", &["receipts-one", "receipts-two"], ROOM);
	let room = fixture.room_id(0);
	run_within(Duration::from_secs(60), async {
		let runtime = host().await;
		let view = attach(&runtime, &fixture.peers[0].link).await;
		let (operation, text) = ("kept-line", "kept, then given back");
		let base = view.revision().await.unwrap();
		assert_eq!(
			view.say_at(operation, base, &room, text).await.unwrap(),
			EffectStatus::Committed
		);
		view.keep_line(operation, base, &room, text).await.unwrap();
		for _ in 0..2 {
			assert_eq!(
				view.release_line(operation, base, &room, text).await.unwrap(),
				Release::Kept
			);
		}
		assert!(!view.held().await.unwrap().contains(&operation.to_owned()));
		assert_eq!(view.holder(operation).await.unwrap(), Holder::Mine);
		drop(view);
		runtime.close(PendingWork::Cancel).await.unwrap();
	});
	fixture.finish();
}

/// The same for a direct conversation's route: it stays open and held.
#[test]
fn giving_back_a_kept_routes_receipt_answers_kept_and_the_route_stays() {
	let fixture = Fixture::start("receipts-kept-route", &["receipts-one", "receipts-two"], ROOM);
	run_within(Duration::from_secs(60), async {
		let runtime = host().await;
		let view = attach(&runtime, &fixture.peers[0].link).await;
		let directory = super::attached::first_directory(&view).await;
		let Reach::Introduce(introduction) = view.reach_direct(&directory, "receipts-two").await.unwrap() else {
			panic!("the peer was already reached")
		};
		let operation = "kept-route";
		let base = view.revision().await.unwrap();
		let conversation = match view.introduce(operation, Some(base), &introduction).await {
			Ok(Opened::Opened { conversation, .. }) => conversation,
			other => panic!("the open did not open: {other:?}"),
		};
		for _ in 0..2 {
			assert_eq!(
				view.release_open(operation, base, &introduction).await.unwrap(),
				Release::Kept
			);
		}
		assert!(!view.held().await.unwrap().contains(&operation.to_owned()));
		assert_eq!(
			view.reach_direct(&directory, "receipts-two").await.unwrap(),
			Reach::Open(conversation)
		);
		drop(view);
		runtime.close(PendingWork::Cancel).await.unwrap();
	});
	fixture.finish();
}

/// A result the view can never keep is given back, so its receipt holds no
/// place: a line posted into a conversation that was closed before anything
/// kept it. The session refuses the keeping for good, where a failure that
/// clears with time keeps the receipt.
#[test]
fn a_line_whose_conversation_is_gone_is_unkept_with_its_receipt_given_back() {
	let fixture = Fixture::start("receipts-unkeepable", &["receipts-one", "receipts-two"], ROOM);
	run_within(Duration::from_secs(60), async {
		let runtime = host().await;
		let view = attach(&runtime, &fixture.peers[0].link).await;
		let directory = super::attached::first_directory(&view).await;
		let Reach::Introduce(introduction) = view.reach_direct(&directory, "receipts-two").await.unwrap() else {
			panic!("the peer was already reached")
		};
		let base = view.revision().await.unwrap();
		let conversation = match view.introduce("unkeepable-open", Some(base), &introduction).await {
			Ok(Opened::Opened { conversation, .. }) => conversation,
			other => panic!("the open did not open: {other:?}"),
		};
		// A second client of the same access posts without keeping.
		let sender = host().await;
		let workspace = second_client(&sender, &fixture.peers[0].link).await;
		let operation = "unkeepable-line";
		let base = view.revision().await.unwrap();
		let command = workspace
			.prepare_command(operation, base, "say", &[conversation.clone(), "never kept".to_owned()])
			.await
			.unwrap();
		let mut status = command.submit().await.unwrap();
		while status == EffectStatus::Pending {
			status = command.receive().await.unwrap();
		}
		assert_eq!(status, EffectStatus::Committed);
		assert!(view.held().await.unwrap().contains(&operation.to_owned()));
		let base = view.revision().await.unwrap();
		assert_eq!(
			view.command(
				"unkeepable-close",
				base,
				"closeDirect",
				std::slice::from_ref(&conversation)
			)
			.await
			.unwrap(),
			EffectStatus::Committed
		);
		let settled = view.settle_effect(operation).await;
		assert!(
			matches!(
				&settled,
				Err(Error::Unkept {
					receipt: GiveBack::Released,
					cause,
					..
				}) if cause.refuses_keeping()
			),
			"{settled:?}"
		);
		assert!(
			!view.held().await.unwrap().contains(&operation.to_owned()),
			"a result that can never be kept holds no place"
		);
		drop((view, command, workspace));
		sender.close(PendingWork::Cancel).await.unwrap();
		runtime.close(PendingWork::Cancel).await.unwrap();
	});
	fixture.finish();
}

/// Send `ensureRoomLink` for `room` under `operation` through `view`, again
/// while the session paces it, and return what the view answered.
async fn link_command(view: &View<HostPlatform>, operation: &str, room: &str) -> Result<EffectStatus, Error> {
	loop {
		let base = view.revision().await.unwrap();
		match view
			.command(operation, base, "ensureRoomLink", &[room.to_owned()])
			.await
		{
			Err(Error::Peer(cause))
				if cause.failure_code() == Some(rooms_application::failure::FailureCode::RateLimited) =>
			{
				tokio::time::sleep(Duration::from_millis(200)).await;
			}
			other => return other,
		}
	}
}

/// A command whose result carries a capability nothing here keeps, such as a
/// room link, is refused before it is sent, so it takes no receipt and never
/// reaches the view's forfeit, however many are sent. One sent by a client
/// that keeps nothing, as an older bot could leave it, holds a place until
/// the view settles it, and then it is forfeited and its receipt given back.
#[test]
fn a_capability_result_nothing_keeps_is_refused_before_sending_and_a_recovered_one_forfeited() {
	let fixture = Fixture::start("receipts-forfeit", &["receipts-one"], ROOM);
	let room = fixture.room_id(0);
	let link = fixture.peers[0].link.clone();
	run_within(Duration::from_secs(60), async {
		let runtime = host().await;
		let view = attach(&runtime, &link).await;
		for round in 0..=MAX_EFFECTS {
			let operation = format!("forfeit-{round}");
			let sent = link_command(&view, &operation, &room).await;
			assert!(
				matches!(&sent, Err(Error::Unkeepable { command }) if command == "ensureRoomLink"),
				"round {round}: {sent:?}"
			);
			assert!(!view.held().await.unwrap().contains(&operation));
			assert!(!forfeit_reached(&operation), "round {round} reached the forfeit");
		}
		// A second host sends as a client that keeps nothing.
		let sender = host().await;
		let workspace = second_client(&sender, &link).await;
		let operation = "forfeit-recovered".to_owned();
		let base = view.revision().await.unwrap();
		let command = workspace
			.prepare_command(&operation, base, "ensureRoomLink", std::slice::from_ref(&room))
			.await
			.unwrap();
		let mut status = command.submit().await.unwrap();
		while status == EffectStatus::Pending {
			status = command.receive().await.unwrap();
		}
		assert_eq!(status, EffectStatus::Committed);
		assert!(
			view.held().await.unwrap().contains(&operation),
			"a result nothing kept holds a place"
		);
		let settled = view.settle_effect(&operation).await;
		assert!(
			matches!(
				settled,
				Err(Error::Forfeited {
					receipt: GiveBack::Released,
					..
				})
			),
			"{settled:?}"
		);
		assert!(
			forfeit_reached(&operation),
			"the recovered result never reached the forfeit"
		);
		assert!(!view.held().await.unwrap().contains(&operation));
		drop((view, command, workspace));
		sender.close(PendingWork::Cancel).await.unwrap();
		runtime.close(PendingWork::Cancel).await.unwrap();
	});
	fixture.finish();
}

/// Paused executors fill every receipt place, and the session refuses
/// another request with the coded full-window refusal, so a caller knows
/// nothing was sent and that a freed place clears it.
#[test]
fn a_window_full_of_paused_executors_refuses_another_request_as_receipts_full() {
	let mut fixture = Fixture::start_on("receipts-paused-full", &["receipts-paused"], ROOM, &[free_port()]);
	fixture.peers[0].restart_at(Some("expire-line-observations"));
	let management = std::fs::read_to_string(fixture.peers[0].state.join("management.sturdyref")).unwrap();
	let room = fixture.room_id(0);
	run_within(Duration::from_secs(60), async {
		let issuer = host().await;
		let grants = Grants::attach(&issuer, HostPlatform, &management).await.unwrap();
		let terms = Terms::new(Preset::Collaborator.values()).unwrap();
		let issued = grants.issue("the pauser", &terms).await.unwrap();
		let holder = host().await;
		let view = attach(&holder, &issued.link).await;
		let mut held = 0;
		let mut refused = None;
		for round in 0.. {
			let base = view.revision().await.unwrap();
			match view
				.say_at(&format!("paused-{round}"), base, &room, &format!("paused {round}"))
				.await
			{
				Err(Error::Peer(cause))
					if cause.failure_code() == Some(rooms_application::failure::FailureCode::RateLimited) =>
				{
					tokio::time::sleep(Duration::from_millis(200)).await;
				}
				// The restarted session takes the room's seat again before
				// it posts there.
				Err(Error::Peer(cause)) if held == 0 && cause.failure_code().is_none() => {
					tokio::time::sleep(Duration::from_millis(200)).await;
				}
				Err(Error::Peer(cause)) if held == MAX_EFFECTS => {
					refused = Some(cause);
					break;
				}
				// A paused line's outcome is unknown, and it holds its place.
				Ok(EffectStatus::Unknown) => {
					held += 1;
					assert!(
						held <= MAX_EFFECTS,
						"more paused lines were taken than the session has places"
					);
				}
				other => panic!("round {round}: {other:?}"),
			}
		}
		let cause = refused.unwrap();
		assert_eq!(
			cause.failure_code(),
			Some(rooms_application::failure::FailureCode::ReceiptsFull),
			"{cause}"
		);
		drop(view);
		holder.close(PendingWork::Cancel).await.unwrap();
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	fixture.finish();
}
