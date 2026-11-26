//! A job whose settlement committed but whose answer came late pauses with its
//! receipt settled, and a later admission or a release retires it. Against real
//! session processes.
use super::receipts::ROOM;
use super::session_rig::{Fixture, attach, free_port, host, run_within};
use super::*;
use glowcap::PendingWork;
use rooms_application::content::session::custody::MAX_EFFECTS;
use rooms_platform::HostPlatform;
use rooms_services::session::attached::{EffectStatus, Error, GiveBack, Opened, Reach, Release, View};

/// A client of the access `link` names, on `runtime`, which sends and reads
/// as that same access without a view's keeping.
pub(super) async fn second_client(
	runtime: &glowcap::Runtime,
	link: &str,
) -> rooms_glowcap::client::workspace::Workspace<HostPlatform> {
	let parsed = glowcap::parse_sturdyref(link.trim(), glowcap::CaptpVersion::V1_0).unwrap();
	let connection = runtime
		.connect(&parsed.locator, glowcap::ConnectOptions::default())
		.await
		.unwrap();
	let reference = connection
		.fetch(std::str::from_utf8(&parsed.swissnum).unwrap())
		.await
		.unwrap();
	rooms_glowcap::client::workspace::Workspace::new(
		rooms_glowcap::client::Client::new(connection, HostPlatform),
		reference,
	)
}

/// Whether the session still holds a paused or running job for `operation`,
/// read from the access's own receipt inventory.
async fn resumable(workspace: &rooms_glowcap::client::workspace::Workspace<HostPlatform>, operation: &str) -> bool {
	let effects = workspace.effects().await.unwrap();
	let entry = effects.iter().find(|entry| entry.operation == operation);
	entry.unwrap_or_else(|| panic!("no receipt for {operation}")).resumable
}

/// Wait for the restarted session to adopt its seat before testing what a post does.
pub(super) async fn wait_for_room_seat(view: &View<HostPlatform>, room: &str) {
	let deadline = Instant::now() + Duration::from_secs(10);
	loop {
		let snapshot = view.snapshot().await.unwrap();
		if snapshot.intent.room(room).is_some_and(|row| row.seat.is_some()) {
			return;
		}
		assert!(
			Instant::now() < deadline,
			"the restarted session never regained its seat in {room}"
		);
		tokio::time::sleep(Duration::from_millis(50)).await;
	}
}

/// Post at the current base, retrying only the session's pacing refusal.
pub(super) async fn post_when_paced(
	view: &View<HostPlatform>,
	operation: &str,
	room: &str,
	text: &str,
) -> (u64, Result<EffectStatus, Error>) {
	loop {
		let base = view.revision().await.unwrap();
		match view.say_at(operation, base, room, text).await {
			Err(Error::Peer(cause))
				if cause.failure_code() == Some(rooms_application::failure::FailureCode::RateLimited) =>
			{
				tokio::time::sleep(Duration::from_millis(200)).await;
			}
			other => return (base, other),
		}
	}
}

/// A job whose settlement committed but whose answer came late pauses with
/// its receipt settled. The next admission retires it, so it holds no seat:
/// more kept lines than the session has places are each taken.
#[test]
fn executors_whose_settlement_answer_came_late_hold_no_seat() {
	let mut fixture = Fixture::start_on("receipts-late-settled", &["receipts-late"], ROOM, &[free_port()]);
	fixture.peers[0].restart_at(Some("late-line-settlements"));
	let room = fixture.room_id(0);
	let link = fixture.peers[0].link.clone();
	run_within(Duration::from_secs(60), async {
		let runtime = host().await;
		let view = attach(&runtime, &link).await;
		// One runtime holds one connection to the session, so the reader runs
		// on its own.
		let reading = host().await;
		let reader = second_client(&reading, &link).await;
		wait_for_room_seat(&view, &room).await;
		for round in 0..=MAX_EFFECTS {
			let (operation, text) = (format!("late-{round}"), format!("late {round}"));
			let (base, status) = post_when_paced(&view, &operation, &room, &text).await;
			assert_eq!(status.unwrap(), EffectStatus::Committed, "round {round}");
			view.keep_line(&operation, base, &room, &text).await.unwrap();
			if round == 0 {
				assert!(resumable(&reader, &operation).await, "the fault never paused the job");
			}
		}
		// The fault pauses every line, so late-1 paused when it settled, and the
		// admission after it retired it. late-0 has left the inventory by now.
		assert!(
			!resumable(&reader, "late-1").await,
			"a later admission did not retire the settled job late-1"
		);
		drop((view, reader));
		reading.close(PendingWork::Cancel).await.unwrap();
		runtime.close(PendingWork::Cancel).await.unwrap();
	});
	fixture.finish();
}

/// A direct line settled late leaves its job paused, its captured line not yet
/// in the sender's activity. The next admission retires it and publishes it.
#[test]
fn retiring_a_late_settled_direct_line_publishes_it() {
	late_settled_direct_line("receipts-late-direct", Retiring::NextAdmission);
}

/// A release of the late line's receipt publishes it, as an admission does.
#[test]
fn releasing_a_late_settled_direct_line_publishes_it() {
	late_settled_direct_line("receipts-late-direct-release", Retiring::Release);
}

/// What retires the settled job that holds a late direct line.
enum Retiring {
	NextAdmission,
	Release,
}

/// A direct line whose settlement committed but whose answer came late leaves
/// its job paused, with the line it captured not yet in the sender's activity.
/// `retiring` names what retires the job and publishes that line.
fn late_settled_direct_line(name: &str, retiring: Retiring) {
	const TEXT: &str = "late direct";
	let mut fixture = Fixture::start_on(name, &["receipts-one", "receipts-two"], ROOM, &[free_port(), 0]);
	fixture.peers[0].restart_at(Some(match retiring {
		Retiring::NextAdmission => "late-line-settlements",
		Retiring::Release => "late-line-settlements-held",
	}));
	let link = fixture.peers[0].link.clone();
	run_within(Duration::from_secs(60), async {
		let runtime = host().await;
		let view = attach(&runtime, &link).await;
		// One runtime holds one connection to the session, so the reader runs
		// on its own.
		let reading = host().await;
		let reader = second_client(&reading, &link).await;
		let directory = super::attached::first_directory(&view).await;
		// The restarted session reaches the peer once it holds its directory
		// seat again. It renews its registration there, and an introduction
		// made before the renewal opens nothing and gives its receipt back, so
		// a new operation introduces again.
		let deadline = Instant::now() + Duration::from_secs(10);
		let mut tries = 0;
		let conversation = loop {
			tries += 1;
			match view.reach_direct(&directory, "receipts-two").await {
				Ok(Reach::Introduce(introduction)) => {
					let base = view.revision().await.unwrap();
					let operation = format!("late-direct-open-{tries}");
					match view.introduce(&operation, Some(base), &introduction).await {
						Ok(Opened::Opened { conversation, .. }) => break conversation,
						Err(Error::Unopened {
							receipt: GiveBack::Released,
							..
						})
						| Ok(Opened::Uncertain(_)) => assert!(Instant::now() < deadline, "the open never opened"),
						// The renewal moved the workspace between the base's read
						// and the send. Nothing was applied, and the next try reads
						// a new base.
						Ok(Opened::Unapplied(sent)) if matches!(sent.status, EffectStatus::Conflict) => {
							assert!(Instant::now() < deadline, "the open never met its base")
						}
						other => panic!("the open did not open: {other:?}"),
					}
				}
				Ok(other) => panic!("the peer was already reached: {other:?}"),
				Err(error) => assert!(Instant::now() < deadline, "the peer was never reached: {error:?}"),
			}
			tokio::time::sleep(Duration::from_millis(200)).await;
		};
		let base = view.revision().await.unwrap();
		// A view adopts its line and an adopted receipt's release retires
		// nothing, so the release case sends through the access's own client.
		let mut held = None;
		match retiring {
			Retiring::NextAdmission => {
				let said = view.say("late-direct", &conversation, TEXT).await.unwrap();
				assert_eq!(said.status, EffectStatus::Committed);
			}
			Retiring::Release => {
				let command = reader
					.prepare_command(
						"late-direct",
						base,
						"say",
						&[conversation.to_string(), TEXT.to_string()],
					)
					.await
					.unwrap();
				command.submit().await.unwrap();
				while command.status().await.unwrap() == EffectStatus::Pending {
					tokio::time::sleep(Duration::from_millis(20)).await;
				}
				assert_eq!(command.status().await.unwrap(), EffectStatus::Committed);
				held = Some(command);
			}
		}
		assert!(
			resumable(&reader, "late-direct").await,
			"the fault never paused the job"
		);
		match retiring {
			Retiring::NextAdmission => {
				view.say("late-direct-next", &conversation, "after the late line")
					.await
					.unwrap();
			}
			Retiring::Release => {
				// No admission retires the settled job under this fault, so only
				// the release can. A release answers running until the executor
				// ends, and that answer is the release verb's own signal to ask
				// again, so this asks again on it and on nothing else.
				let command = held.unwrap();
				let deadline = Instant::now() + Duration::from_secs(20);
				loop {
					let answer = command.release().await.unwrap();
					if answer != Release::Running {
						assert_eq!(answer, Release::Released);
						break;
					}
					assert!(Instant::now() < deadline, "the settled job never paused");
					tokio::time::sleep(Duration::from_millis(50)).await;
				}
			}
		}
		assert!(!resumable(&reader, "late-direct").await, "the settled job was left");
		super::attached::until(&view, &mut String::new(), super::attached::said(TEXT)).await;
		drop((view, reader));
		reading.close(PendingWork::Cancel).await.unwrap();
		runtime.close(PendingWork::Cancel).await.unwrap();
	});
	fixture.finish();
}

/// A job paused before its settlement leaves its receipt unresolved, and a
/// later admission leaves that job for its source to resume.
#[test]
fn a_paused_job_whose_receipt_is_unresolved_survives_a_later_admission() {
	let mut fixture = Fixture::start_on("receipts-late-unresolved", &["receipts-late"], ROOM, &[free_port()]);
	fixture.peers[0].restart_at(Some("expire-first-line-observation"));
	let room = fixture.room_id(0);
	let link = fixture.peers[0].link.clone();
	run_within(Duration::from_secs(60), async {
		let runtime = host().await;
		let view = attach(&runtime, &link).await;
		// One runtime holds one connection to the session, so the reader runs
		// on its own.
		let reading = host().await;
		let reader = second_client(&reading, &link).await;
		wait_for_room_seat(&view, &room).await;
		let (_, first) = post_when_paced(&view, "unresolved-0", &room, "unresolved 0").await;
		assert_eq!(first.unwrap(), EffectStatus::Unknown, "the fault never paused the job");
		let (base, second) = post_when_paced(&view, "unresolved-1", &room, "unresolved 1").await;
		assert_eq!(second.unwrap(), EffectStatus::Committed);
		view.keep_line("unresolved-1", base, &room, "unresolved 1")
			.await
			.unwrap();
		assert!(
			resumable(&reader, "unresolved-0").await,
			"an admission retired a job whose receipt is unresolved"
		);
		drop((view, reader));
		reading.close(PendingWork::Cancel).await.unwrap();
		runtime.close(PendingWork::Cancel).await.unwrap();
	});
	fixture.finish();
}
