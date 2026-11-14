//! A verb answered later takes its queue seat before it charges its
//! allowance, so a full queue refuses with that allowance intact. A held
//! introduction has its own bound and takes no seat. A verb answered in its
//! own turn takes no seat and is charged once.
use super::{closing_tolerated, config, runtime, tcp};
use glowcap::{Argument, ConnectOptions, PendingWork};
use rooms_application::{
	admission::{Class, Settings},
	directory::creation::RecoveryKey,
	failure::FailureCode,
	room::subject::Subject,
};
use rooms_glowcap::client::{Client, directory::Directory, room::Room};
use rooms_platform::HostPlatform;
use rooms_testing::scratch::Scratch;
use std::{rc::Rc, time::Duration};

/// A directory serving on loopback with its state in reach, so a test can
/// take every seat of a queue from inside.
struct Served {
	state: super::super::state::Shared,
	location: String,
	stop: tokio::sync::oneshot::Sender<()>,
	task: tokio::task::JoinHandle<Result<(), super::Error>>,
	_storage: Scratch,
}

impl Served {
	/// `rates` replaces the default allowance of the classes it names.
	async fn start(name: &str, rates: Option<&str>) -> Self {
		let storage = Scratch::create(name);
		let admission = Settings::parse(
			|key| rates.filter(|_| key == "admission-rates").map(str::to_owned),
			8192,
			1,
		)
		.unwrap();
		let peer = super::super::peer::Peer::open(
			config(storage.to_path_buf(), tcp(), Default::default(), admission),
			Rc::new(|_| {}),
		)
		.await
		.unwrap();
		let (state, location) = (peer.shared(), peer.location());
		let (stop, stopped) = tokio::sync::oneshot::channel::<()>();
		let task = tokio::task::spawn_local(peer.serve(async {
			let _ = stopped.await;
		}));
		Self {
			state,
			location,
			stop,
			task,
			_storage: storage,
		}
	}

	async fn stop(self) {
		drop(self.state);
		self.stop.send(()).unwrap();
		self.task.await.unwrap().unwrap();
	}
}

/// One more refusal than the class allows at once. Were any of them charged,
/// the last would be a rate limit and not the busy code.
fn refusals(class: Class) -> u32 {
	class.default_rate().burst() + 1
}

#[tokio::test]
async fn a_full_authority_writer_refuses_a_subject_and_a_room_link_before_charging_them() {
	// Small enough to run out within the test, and more than its setup reads.
	const READS: u32 = 64;
	rooms_testing::local_set::run_within(Duration::from_secs(20), async {
		let served = Served::start("writer-seat", Some(&format!("read={READS}/{READS}"))).await;
		let runtime = runtime().await;
		let client = Client::new(
			runtime
				.connect(
					&glowcap::parse_locator(&served.location).unwrap(),
					ConnectOptions::default(),
				)
				.await
				.unwrap(),
			HostPlatform,
		);
		let directory = Directory::fetch(client.clone()).await.unwrap();
		let entrance = directory.open("Seats").await.unwrap();
		let (room, _lines) = Room::subscribe(client.clone(), entrance, "Alice", Default::default())
			.await
			.unwrap();
		let subject = Subject::new("seeds".into(), None).unwrap();
		let seats: Vec<_> = std::iter::from_fn(|| served.state.borrow().authority_writer.reserve().ok()).collect();
		assert!(!seats.is_empty());
		for _ in 0..refusals(Class::Message) {
			let refused = room.set_subject(&subject).await.expect_err("the writer is full");
			assert_eq!(refused.failure_code(), Some(FailureCode::AdmissionBusy), "{refused}");
		}
		for _ in 0..=READS {
			let refused = directory.link("Seats").await.expect_err("the writer is full");
			assert_eq!(refused.failure_code(), Some(FailureCode::AdmissionBusy), "{refused}");
		}
		drop(seats);
		room.set_subject(&subject).await.unwrap();
		directory.link("Seats").await.unwrap();
		room.leave().await.unwrap();
		closing_tolerated(client.session().close(PendingWork::Cancel).await);
		served.stop().await;
		runtime.close(PendingWork::Cancel).await.unwrap();
	})
	.await;
}

#[tokio::test]
async fn a_full_work_queue_refuses_a_signaling_offer_and_an_inbox_offer_before_charging_them() {
	rooms_testing::local_set::run_within(Duration::from_secs(30), async {
		let served = Served::start("work-seat", None).await;
		let dial = glowcap::parse_locator(&served.location).unwrap();
		let (bob_runtime, carol_runtime) = (runtime().await, runtime().await);
		let bob = Client::new(
			bob_runtime.connect(&dial, ConnectOptions::default()).await.unwrap(),
			HostPlatform,
		);
		let carol = Client::new(
			carol_runtime.connect(&dial, ConnectOptions::default()).await.unwrap(),
			HostPlatform,
		);
		let (bob_dir, carol_dir) = (
			Directory::fetch(bob.clone()).await.unwrap(),
			Directory::fetch(carol.clone()).await.unwrap(),
		);
		let mut bob_name = bob_dir.registration();
		let bob_id = bob_name.register("Bob", "127.0.0.1:9", None).await.unwrap().id;
		let mut carol_name = carol_dir.registration();
		carol_name
			.register("Carol", "ocapn://silent.webrtc", None)
			.await
			.unwrap();
		let silent = carol.session().spawn_owned(|_, _| Ok(Argument::Void)).unwrap();
		carol_dir.signaling().offer_signaling(&silent).await.unwrap();
		let reply = bob.session().spawn_owned(|_, _| Ok(Argument::Void)).unwrap();
		let offer = || {
			bob.session().send(
				bob_dir.reference(),
				rooms_application::signaling::OFFER,
				&["silent".into(), "v=0".into(), reply.clone().into()],
			)
		};
		let seats: Vec<_> = std::iter::from_fn(|| served.state.borrow().reserve().ok()).collect();
		assert!(!seats.is_empty());
		for _ in 0..refusals(Class::Signal) {
			let refused = offer().await.expect_err("the work queue is full");
			assert_eq!(
				rooms_glowcap::client::binding_failure(&refused).map(|failure| failure.code),
				Some(FailureCode::AdmissionBusy),
				"{refused}"
			);
		}
		for _ in 0..refusals(Class::Create) {
			let refused = bob_dir
				.offer_inbox("Carol", &bob_id, "opening", &reply)
				.await
				.expect_err("the work queue is full");
			assert_eq!(refused.failure_code(), Some(FailureCode::AdmissionBusy), "{refused}");
		}
		drop(seats);
		offer().await.unwrap();
		// The inbox offer reaches the directory with its allowance whole, and
		// is refused for naming a registration that is not Carol's.
		let mismatched = bob_dir
			.offer_inbox("Carol", &bob_id, "opening", &reply)
			.await
			.expect_err("the registration ID is Bob's own");
		assert_eq!(
			mismatched.failure_code(),
			Some(FailureCode::PeerOffline),
			"{mismatched}"
		);
		drop((reply, silent, bob_name, carol_name, bob_dir, carol_dir));
		closing_tolerated(bob.session().close(PendingWork::Cancel).await);
		closing_tolerated(carol.session().close(PendingWork::Cancel).await);
		served.stop().await;
		for runtime in [bob_runtime, carol_runtime] {
			runtime.close(PendingWork::Cancel).await.unwrap();
		}
	})
	.await;
}

#[tokio::test]
async fn a_full_work_queue_still_holds_an_introduction() {
	held_introduction(Ending::CarolLeaves).await;
}

#[tokio::test]
async fn a_stopping_server_ends_the_introduction_it_holds() {
	held_introduction(Ending::ServerStops).await;
}

/// What ends the introduction Bob is waiting on.
enum Ending {
	CarolLeaves,
	ServerStops,
}

/// Bob introduces himself to Carol while every work seat is taken, and the
/// server holds the introduction until `ending`.
async fn held_introduction(ending: Ending) {
	rooms_testing::local_set::run_within(Duration::from_secs(30), async {
		let served = Served::start("held-introduction", None).await;
		let dial = glowcap::parse_locator(&served.location).unwrap();
		let (bob_runtime, carol_runtime) = (runtime().await, runtime().await);
		let bob = Client::new(
			bob_runtime.connect(&dial, ConnectOptions::default()).await.unwrap(),
			HostPlatform,
		);
		let carol = Client::new(
			carol_runtime.connect(&dial, ConnectOptions::default()).await.unwrap(),
			HostPlatform,
		);
		let (bob_dir, carol_dir) = (
			Directory::fetch(bob.clone()).await.unwrap(),
			Directory::fetch(carol.clone()).await.unwrap(),
		);
		let mut bob_name = bob_dir.registration();
		let bob_id = bob_name.register("Bob", "127.0.0.1:9", None).await.unwrap().id;
		let mut carol_name = carol_dir.registration();
		let carol_id = carol_name.register("Carol", "127.0.0.1:9", None).await.unwrap().id;
		let seats: Vec<_> = std::iter::from_fn(|| served.state.borrow().reserve().ok()).collect();
		assert!(!seats.is_empty());
		let mut introducing = tokio::task::spawn_local({
			let (bob, directory) = (bob.clone(), bob_dir.reference().clone());
			async move {
				bob.session()
					.send(
						&directory,
						rooms_application::protocol_data::INTRODUCE,
						&["Carol".into(), carol_id.as_str().into(), "opening".into()],
					)
					.await
			}
		});
		// Carol is asked for her inbox while every work seat is taken. A
		// refusal for the full queue would end the introduction first.
		let asked = tokio::select! {
			asked = carol_name.next() => asked.unwrap().unwrap(),
			ended = &mut introducing => panic!(
				"the introduction ended before Carol was asked: {:?}",
				ended.unwrap().map(drop).map_err(|refused| refused.to_string())
			),
		};
		assert_eq!(asked.registration, bob_id);
		drop((carol_name, carol_dir, bob_name, bob_dir));
		match ending {
			Ending::CarolLeaves => {
				// Her leaving is the held introduction's answer, and the full
				// queue is not.
				closing_tolerated(carol.session().close(PendingWork::Cancel).await);
				let refused = introducing
					.await
					.unwrap()
					.expect_err("Carol left before offering an inbox");
				assert_eq!(
					rooms_glowcap::client::binding_failure(&refused).map(|failure| failure.code),
					Some(FailureCode::PeerOffline),
					"{refused}"
				);
				drop(seats);
				closing_tolerated(bob.session().close(PendingWork::Cancel).await);
				served.stop().await;
			}
			Ending::ServerStops => {
				// The server closes its connections, which ends what it held
				// for them, and it waits for that before it returns.
				drop(seats);
				let state = served.state.clone();
				served.stop().await;
				assert!(
					state.borrow().introductions.tasks.is_empty(),
					"the server returned with an introduction still held"
				);
				drop(state);
				introducing
					.await
					.unwrap()
					.expect_err("the server stopped before Carol offered an inbox");
				closing_tolerated(carol.session().close(PendingWork::Cancel).await);
				closing_tolerated(bob.session().close(PendingWork::Cancel).await);
			}
		}
		for runtime in [bob_runtime, carol_runtime] {
			runtime.close(PendingWork::Cancel).await.unwrap();
		}
	})
	.await;
}

/// Linking a saved publication reads one room. It costs one read when this
/// server holds the room and one when the ID names none, and subscribing to
/// an ID that names none is that same read.
#[tokio::test]
async fn a_saved_publication_costs_one_read_whether_or_not_it_names_a_room() {
	use rooms_application::directory::creation::{LINK_PUBLICATION, SUBSCRIBE_PUBLICATION};
	// One read comes back every ten seconds, which is longer than the
	// counting takes.
	const READS: u32 = 6;
	const NO_ROOM: &str = "00000000-0000-4000-8000-000000000000";
	rooms_testing::local_set::run_within(Duration::from_secs(20), async {
		let served = Served::start("publication-read", Some(&format!("read={READS}/{READS}"))).await;
		let dial = glowcap::parse_locator(&served.location).unwrap();
		let (keeper_runtime, reader_runtime) = (runtime().await, runtime().await);
		// The keeper opens the room and learns its publication on its own
		// allowance, so the reader's is whole when the counting starts.
		let keeper = Client::new(
			keeper_runtime.connect(&dial, ConnectOptions::default()).await.unwrap(),
			HostPlatform,
		);
		let keeper_dir = Directory::fetch(keeper.clone()).await.unwrap();
		let entrance = keeper_dir.open("Orchard").await.unwrap();
		let (room, _lines) = Room::subscribe(keeper.clone(), entrance, "Keeper", Default::default())
			.await
			.unwrap();
		let saved = keeper_dir.link("Orchard").await.unwrap();
		let named = keeper
			.session()
			.send(
				keeper_dir.reference(),
				rooms_application::directory::NAMED,
				&["Orchard".into()],
			)
			.await
			.unwrap();
		let publication = rooms_application::directory::rooms(&rooms_glowcap::Value(&named))
			.unwrap()
			.remove(0)
			.id
			.text()
			.as_str()
			.unwrap()
			.to_owned();
		let reader = Client::new(
			reader_runtime.connect(&dial, ConnectOptions::default()).await.unwrap(),
			HostPlatform,
		);
		let reader_dir = Directory::fetch(reader.clone()).await.unwrap();
		let link = |id: &str| {
			reader
				.session()
				.send(reader_dir.reference(), LINK_PUBLICATION, &[id.into()])
		};
		let code =
			|refused: &glowcap::Error| rooms_glowcap::client::binding_failure(refused).map(|failure| failure.code);
		for turn in 0..READS {
			if turn % 2 == 0 {
				assert_eq!(link(&publication).await.unwrap().as_str(), Some(saved.as_str()));
			} else {
				let refused = link(NO_ROOM).await.expect_err("the ID names no room");
				assert_eq!(code(&refused), Some(FailureCode::NoSuchRoom), "{refused}");
			}
		}
		let spent = link(&publication).await.expect_err("the read allowance is spent");
		assert_eq!(code(&spent), Some(FailureCode::RateLimited), "{spent}");
		let inbox = reader.session().spawn_owned(|_, _| Ok(Argument::Void)).unwrap();
		let spent = reader
			.session()
			.send(
				reader_dir.reference(),
				SUBSCRIBE_PUBLICATION,
				&[NO_ROOM.into(), "Reader".into(), inbox.clone().into()],
			)
			.await
			.expect_err("the read allowance is spent");
		assert_eq!(code(&spent), Some(FailureCode::RateLimited), "{spent}");
		drop((inbox, reader_dir));
		room.leave().await.unwrap();
		closing_tolerated(reader.session().close(PendingWork::Cancel).await);
		closing_tolerated(keeper.session().close(PendingWork::Cancel).await);
		served.stop().await;
		for runtime in [keeper_runtime, reader_runtime] {
			runtime.close(PendingWork::Cancel).await.unwrap();
		}
	})
	.await;
}

/// Asking for a private room's link records the room, so it spends what
/// opening a room spends. A repeat of a recorded key spends it too, because
/// the charge comes before the answer.
#[tokio::test]
async fn a_private_rooms_link_is_charged_as_a_creation() {
	// One creation comes back every thirty seconds, which is longer than the
	// counting takes.
	rooms_testing::local_set::run_within(Duration::from_secs(20), async {
		let served = Served::start("private-link-charge", Some("create=2/2")).await;
		let runtime = runtime().await;
		let client = Client::new(
			runtime
				.connect(
					&glowcap::parse_locator(&served.location).unwrap(),
					ConnectOptions::default(),
				)
				.await
				.unwrap(),
			HostPlatform,
		);
		let directory = Directory::fetch(client.clone()).await.unwrap();
		let key = |room: u8| RecoveryKey::from_entropy([room; 16]);
		// Opening a room and asking for a private room's link draw on one
		// allowance.
		directory.open("Charged").await.unwrap();
		directory.private_link(&key(0)).await.unwrap();
		for room in [1, 0] {
			let refused = directory
				.private_link(&key(room))
				.await
				.expect_err("the creation allowance is spent");
			assert_eq!(refused.failure_code(), Some(FailureCode::RateLimited), "{refused}");
		}
		// The refused key was never recorded, and a read still answers.
		assert!(!served.state.borrow().authority.room_link_active(key(1).as_str()));
		assert!(served.state.borrow().authority.room_link_active(key(0).as_str()));
		directory.list(None).await.unwrap();
		closing_tolerated(client.session().close(PendingWork::Cancel).await);
		served.stop().await;
		runtime.close(PendingWork::Cancel).await.unwrap();
	})
	.await;
}
