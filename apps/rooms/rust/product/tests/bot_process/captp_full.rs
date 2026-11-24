//! A real session whose every receipt place another access holds. The
//! session refuses the bot's reply before dispatching it, so the bot keeps
//! the line, shows the wait in `status`, and posts it once a place is free,
//! across a restart of the session too.
use super::captp::{BOT, World};
use super::captp_crashes::{answered, once_and_still_open, still_open};
use super::rig::eventually;
use super::session_rig::{attach, host, run_within};
use super::words;
use glowcap::PendingWork;
use rooms_application::{content::session::custody::MAX_EFFECTS, failure::FailureCode};
use rooms_services::session::attached::{EffectStatus, Error, Release};
use serde_json::Value;
use std::{collections::BTreeSet, time::Duration};

/// The lines an issued access posted and never kept, one in each receipt
/// place. Each holds its place until that access gives it back.
struct Held {
	link: String,
	room: String,
	lines: Vec<(String, u64, String)>,
}

impl Held {
	async fn every_place(world: &World) -> Self {
		Self::places(world, MAX_EFFECTS).await
	}

	/// Hold `count` places.
	async fn places(world: &World, count: usize) -> Self {
		let (issuer, grants, terms) = world.issuer().await;
		let issued = grants.issue("the holder", &terms).await.unwrap();
		issuer.close(PendingWork::Cancel).await.unwrap();
		let room = world.fixture.room_id(0);
		let holder = host().await;
		let view = attach(&holder, &issued.link).await;
		let mut lines = Vec::new();
		while lines.len() < count {
			let (operation, text) = (format!("held-{}", lines.len()), format!("held {}", lines.len()));
			let base = view.revision().await.unwrap();
			match view.say_at(&operation, base, &room, &text).await {
				Ok(status) => {
					assert_eq!(status, EffectStatus::Committed, "{operation}");
					lines.push((operation, base, text));
				}
				Err(Error::Peer(cause)) if cause.failure_code() == Some(FailureCode::RateLimited) => {
					tokio::time::sleep(Duration::from_millis(200)).await;
				}
				Err(error) => panic!("{operation}: {error}"),
			}
		}
		drop(view);
		holder.close(PendingWork::Cancel).await.unwrap();
		Self {
			link: issued.link,
			room,
			lines,
		}
	}

	/// Give back the first held line's receipt, which frees one place.
	async fn free_one(&self) {
		self.free(&self.lines[..1]).await;
	}

	/// Give back every held line's receipt.
	async fn free_all(&self) {
		self.free(&self.lines).await;
	}

	async fn free(&self, lines: &[(String, u64, String)]) {
		let holder = host().await;
		let view = attach(&holder, &self.link).await;
		for (operation, base, text) in lines {
			let answer = view.release_line(operation, *base, &self.room, text).await.unwrap();
			assert_eq!(answer, Release::Released);
		}
		drop(view);
		holder.close(PendingWork::Cancel).await.unwrap();
	}
}

/// Open the private conversation while places are free, since opening it
/// takes one on the bot's side, and answer the line that opened it.
const OPENING: &str = "the conversation is open";

/// The operations of the tries the full session refused, in order, as the
/// bot's log names them.
fn refused(world: &World) -> Vec<String> {
	world
		.rig
		.log()
		.lines()
		.filter(|line| line.contains(FailureCode::ReceiptsFull.wire()))
		.filter_map(|line| line.split_once("sending operation ")?.1.split_once(' '))
		.map(|(operation, _)| operation.to_owned())
		.collect()
}

/// Every operation the ledger names.
fn operations(ledger: &Value) -> BTreeSet<String> {
	match ledger {
		Value::Object(fields) => fields
			.iter()
			.flat_map(|(key, value)| match (key.as_str(), value) {
				("operation", Value::String(operation)) => BTreeSet::from([operation.clone()]),
				_ => operations(value),
			})
			.collect(),
		Value::Array(values) => values.iter().flat_map(operations).collect(),
		_ => BTreeSet::new(),
	}
}

/// Wait until `status` shows the bot's reply refused by the full session.
fn waiting(world: &World) {
	eventually("the bot to show the full session", || {
		let status = world.rig.status();
		let problem = &status["status"]["last_error"];
		(problem["during"] == "sending"
			&& problem["message"]
				.as_str()
				.is_some_and(|message| message.contains(FailureCode::ReceiptsFull.wire())))
		.then_some(())
	});
}

#[test]
fn a_reply_the_full_session_refused_posts_once_when_a_place_is_freed() {
	let world = World::new("bot-full");
	let text = "posted once a place is free";
	run_within(Duration::from_secs(90), async {
		let bot = world.serve();
		world.dm(&format!("reply:{OPENING}"));
		answered(&world, OPENING);
		let held = Held::every_place(&world).await;
		world.dm(&format!("reply:{text}"));
		waiting(&world);
		assert_eq!(world.count("direct", text), 0, "the reply posted into a full session");
		held.free_one().await;
		answered(&world, text);
		world.stopped(bot);
		held.free_all().await;
	});
	once_and_still_open(&world, &[OPENING, text]);
	world.finish();
}

/// A turn whose agent has stopped and whose reply is going out no longer owns
/// its note. The session holds seven places for another access and one for the
/// turn's pending `--dm` open, so the reply is refused until the serving loop
/// settles the open. The loop does so while the turn still sends, and the
/// reply posts without that access giving anything back.
#[test]
fn the_loop_settles_a_note_of_a_turn_whose_reply_waits_for_its_place() {
	let world = World::new("bot-full-note");
	run_within(Duration::from_secs(90), async {
		let issued = {
			let (issuer, grants, terms) = world.issuer().await;
			let issued = grants.issue("the bot", &terms).await.unwrap();
			issuer.close(PendingWork::Cancel).await.unwrap();
			issued
		};
		let held = Held::places(&world, MAX_EFFECTS - 1).await;
		let bot = world
			.rig
			.serve_linked_at(&issued.link, serde_json::json!({}), Some("view:open-unconfirmed"));
		assert_eq!(
			super::captp_direct::turn(&world, &[super::captp_direct::say(super::captp::FRIEND, "kept")]),
			"exit=1"
		);
		assert!(!refused(&world).is_empty(), "the session never refused the reply");
		eventually("the note to settle and go", || {
			let status = world.rig.status();
			(status["status"]["unsettled_opens"] == 0 && status["status"]["sending"] == 0).then_some(())
		});
		world.stopped(bot);
		held.free_all().await;
	});
	world.finish();
}

/// The bot waits through a restart of the session. Each refused first send
/// goes out again under a new operation. The bot's fifth try is held (the
/// fault `hold-retry@4`) until the place is freed and the session restarted,
/// so the restarted session takes its room seat in the freed place and the
/// bot's next first send posts there under an operation no session refused.
/// The place is freed before the restart because a session that restarts with
/// every place held cannot take its seat. The reply is to a mention in the
/// room, because a restart closes every private conversation.
#[test]
fn a_reply_waiting_for_a_place_survives_a_session_restart_and_posts_once() {
	let mut world = World::new("bot-full-restart");
	let text = "posted once after the restart";
	run_within(Duration::from_secs(120), async {
		let bot = world.serve_at(Some("hold-retry@4"));
		let held = Held::every_place(&world).await;
		world.room(&format!("@{BOT} reply:{text}"));
		waiting(&world);
		eventually("the bot to hold its fifth try", || {
			world.rig.dir.join("retry-held").exists().then_some(())
		});
		let tries = refused(&world);
		assert_eq!(tries.len(), 4, "the hold came after four refusals: {tries:?}");
		let distinct: BTreeSet<_> = tries.iter().collect();
		assert_eq!(
			distinct.len(),
			tries.len(),
			"a refused operation was sent again: {tries:?}"
		);
		let next = operations(&world.rig.ledger());
		assert!(
			!next.contains(&tries[0]),
			"the line kept the first refused operation {}: {next:?}",
			tries[0]
		);
		held.free_one().await;
		let joins = world.count_starting("room", &format!("{BOT} joined"));
		world.fixture.peers[0].restart_at(None);
		// The restarted session takes its room seat before it takes a request.
		eventually("the restarted session to take its seat", || {
			(world.count_starting("room", &format!("{BOT} joined")) > joins).then_some(())
		});
		assert_eq!(world.count("room", text), 0, "the reply posted before the restart");
		std::fs::write(world.rig.dir.join("retry-go"), b"").unwrap();
		world.await_line("room", text);
		assert_eq!(refused(&world), tries, "the bot was refused again after the restart");
		world.stopped(bot);
		held.free_all().await;
	});
	assert_eq!(world.count("room", text), 1);
	assert_eq!(world.count_starting("room", words::COULD_NOT_ANSWER), 0);
	assert_eq!(world.rig.status()["status"]["unconfirmed"], 0);
	still_open(&world);
	world.finish();
}
