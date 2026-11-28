//! A request whose executor the real session pauses. The session fault
//! `expire-first-line-observation` makes the first observation of a posted
//! line after a restart expire at once, as the observation deadline does, so
//! the executor of that line pauses and its receipt reads unknown. The paused
//! receipt holds a place until its sender releases it or the sender's access
//! is revoked, and it never keeps the session from stopping.
use super::receipts::posted;
use super::session_rig::{Fixture, attach, free_places, free_port, host, run_within};
use super::*;
use glowcap::PendingWork;
use rooms_application::content::session::{Preset, Terms, custody::MAX_EFFECTS};
use rooms_platform::HostPlatform;
use rooms_services::session::attached::{EffectStatus, Grants, Issued, Release};

const ROOM: &str = "paused-room";
const TEXT: &str = "said while the observation expired";

/// One line whose executor paused, and what a test needs to act on it.
struct Paused {
	/// The host the grants are held over, for the test to close.
	issuer: glowcap::Runtime,
	grants: Grants<HostPlatform>,
	/// The access that sent the line.
	issued: Issued,
	room: String,
	/// The line's operation and the base it was sent at.
	operation: String,
	base: u64,
}

/// Restart the first member armed with the fault, and send one line from a
/// new collaborator access, whose executor pauses.
async fn paused(fixture: &mut Fixture) -> Paused {
	fixture.peers[0].restart_at(Some("expire-first-line-observation"));
	let room = fixture.room_id(0);
	let management = std::fs::read_to_string(fixture.peers[0].state.join("management.sturdyref")).unwrap();
	let issuer = host().await;
	let grants = Grants::attach(&issuer, HostPlatform, &management).await.unwrap();
	let terms = Terms::new(Preset::Collaborator.values()).unwrap();
	let issued = grants.issue("the sender", &terms).await.unwrap();
	let sender = host().await;
	let view = attach(&sender, &issued.link).await;
	// The restarted session refuses a line until its room is joined again,
	// before any executor runs, so each try goes out under a new operation.
	let deadline = Instant::now() + Duration::from_secs(10);
	let mut tries = 0;
	let (operation, base) = loop {
		tries += 1;
		let operation = format!("paused-{tries}");
		let base = view.revision().await.unwrap();
		match view.say_at(&operation, base, &room, TEXT).await {
			Ok(EffectStatus::Conflict) => assert!(Instant::now() < deadline, "the line kept conflicting"),
			Ok(EffectStatus::Pending | EffectStatus::Unknown) => break (operation, base),
			Ok(EffectStatus::Committed) => panic!("the fault never fired"),
			Ok(EffectStatus::Unsent) => panic!("the session did not dispatch the line"),
			Err(error) => assert!(Instant::now() < deadline, "the line was never admitted: {error}"),
		}
		tokio::time::sleep(Duration::from_millis(200)).await;
	};
	let arguments = [room.clone(), TEXT.to_owned()];
	loop {
		match view.observe(&operation, base, "say", &arguments).await {
			Ok(EffectStatus::Unknown) => break,
			observed => assert!(Instant::now() < deadline, "the executor never paused: {observed:?}"),
		}
		tokio::time::sleep(Duration::from_millis(100)).await;
	}
	drop(view);
	sender.close(PendingWork::Cancel).await.unwrap();
	Paused {
		issuer,
		grants,
		issued,
		room,
		operation,
		base,
	}
}

/// The session revokes an access and then gives back every receipt of it
/// that no longer runs, a paused one included, so its place is free again.
#[test]
fn a_revoked_access_gives_back_its_paused_receipt() {
	let mut fixture = Fixture::start_on("paused-swept", &["paused-one", "paused-two"], ROOM, &[free_port(), 0]);
	run_within(Duration::from_secs(90), async {
		let Paused {
			issuer,
			grants,
			issued,
			room,
			..
		} = paused(&mut fixture).await;
		assert_eq!(
			free_places(&grants, &room, "filler-one", Duration::ZERO).await,
			MAX_EFFECTS - 1,
			"the paused receipt holds a place"
		);
		grants.revoke(&issued.name).await.unwrap();
		assert_eq!(
			free_places(&grants, &room, "filler-two", Duration::from_secs(10)).await,
			1,
			"the revoked access's paused receipt was never given back"
		);
		issuer.close(PendingWork::Cancel).await.unwrap();
	});
	fixture.finish();
}

/// A session that holds a paused executor stops on TERM, cleanly and within
/// the process deadline.
#[test]
fn a_session_holding_a_paused_executor_stops_on_term() {
	let mut fixture = Fixture::start_on("paused-term", &["term-one", "term-two"], ROOM, &[free_port(), 0]);
	run_within(Duration::from_secs(60), async {
		paused(&mut fixture)
			.await
			.issuer
			.close(PendingWork::Cancel)
			.await
			.unwrap();
	});
	fixture.finish();
}

/// The sender's release settles its paused line's receipt and keeps it, so
/// the same line sent again at the same base by its sender is answered from
/// the receipt, the same line from another access is refused, and the room
/// sees the line once.
#[test]
fn a_released_paused_line_answers_its_resend_and_posts_once() {
	let mut fixture = Fixture::start_on("paused-resend", &["resend-one", "resend-two"], ROOM, &[free_port(), 0]);
	run_within(Duration::from_secs(90), async {
		let line = paused(&mut fixture).await;
		let sender = host().await;
		let view = attach(&sender, &line.issued.link).await;
		let (operation, base, room) = (&line.operation, line.base, &line.room);
		assert_eq!(
			view.release_line(operation, base, room, TEXT).await.unwrap(),
			Release::Released
		);
		assert_eq!(
			view.say_at(operation, base, room, TEXT).await.unwrap(),
			EffectStatus::Unknown,
			"the sender's resend is answered from the released receipt"
		);
		let terms = Terms::new(Preset::Collaborator.values()).unwrap();
		let other = line.grants.issue("another sender", &terms).await.unwrap();
		let elsewhere = host().await;
		let another = attach(&elsewhere, &other.link).await;
		let refused = another.say_at(operation, base, room, TEXT).await.unwrap_err();
		assert!(
			refused.to_string().contains("original source capability required"),
			"another access sending the same operation is refused as not its sender: {refused}"
		);
		another
			.say("paused-resend-marker", room, "after the resends")
			.await
			.unwrap();
		drop((view, another));
		sender.close(PendingWork::Cancel).await.unwrap();
		elsewhere.close(PendingWork::Cancel).await.unwrap();
		line.issuer.close(PendingWork::Cancel).await.unwrap();
	});
	assert_eq!(
		posted(&fixture.peers[1].state, TEXT, "after the resends"),
		1,
		"the paused line was dispatched once and never again"
	);
	fixture.finish();
}

/// Once its sender releases its paused line, the receipt holds no place: a
/// new access fills every place the session has.
#[test]
fn a_released_paused_line_frees_every_place() {
	let mut fixture = Fixture::start_on("paused-freed", &["freed-one", "freed-two"], ROOM, &[free_port(), 0]);
	run_within(Duration::from_secs(90), async {
		let line = paused(&mut fixture).await;
		let sender = host().await;
		let view = attach(&sender, &line.issued.link).await;
		assert_eq!(
			view.release_line(&line.operation, line.base, &line.room, TEXT)
				.await
				.unwrap(),
			Release::Released
		);
		drop(view);
		sender.close(PendingWork::Cancel).await.unwrap();
		assert_eq!(
			free_places(&line.grants, &line.room, "filler", Duration::ZERO).await,
			MAX_EFFECTS,
			"the released receipt still holds a place"
		);
		line.issuer.close(PendingWork::Cancel).await.unwrap();
	});
	fixture.finish();
}
