//! The directory peer under real CapTP: registration and its name capability,
//! watching, introduction through a three-party handoff, direct requests,
//! signaling relay with its timeout, identity across restart, and shutdown.
use super::*;
use rooms_platform::HostPlatform;
mod admission;
mod admission_pressure;
mod config;
mod operations;
mod receipt_cost;
mod rooms;
use glowcap::{Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig, Session, iroh, tcp};
use rooms_application::{
	directory::{Event, MemberChange, registration::Kind},
	signaling::{Description, Incoming},
};
use rooms_glowcap::client::{Client, directory::Directory};
use std::{
	cell::RefCell,
	path::PathBuf,
	rc::Rc,
	sync::atomic::{AtomicU64, Ordering},
	time::Duration,
};

static NEXT: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp {
	fn new() -> Self {
		let path = std::env::temp_dir().join(format!(
			"rooms-server-{}-{}",
			std::process::id(),
			NEXT.fetch_add(1, Ordering::Relaxed)
		));
		std::fs::create_dir(&path).unwrap();
		Self(path)
	}
}
impl Drop for Temp {
	fn drop(&mut self) {
		let _ = std::fs::remove_dir_all(&self.0);
	}
}

struct Running {
	stop: tokio::sync::oneshot::Sender<()>,
	task: tokio::task::JoinHandle<Result<(), Error>>,
	location: String,
	capabilities: Vec<Minted>,
	trace: Option<String>,
	notices: Rc<RefCell<Vec<String>>>,
}

async fn start(state: PathBuf, transport: Transport) -> Running {
	start_with(state, transport, Asked::default()).await
}

async fn start_with(state: PathBuf, transport: Transport, asked: Asked) -> Running {
	start_with_admission(
		state,
		transport,
		asked,
		rooms_application::admission::Settings::defaults(8192, 1),
	)
	.await
}
async fn start_with_admission(
	state: PathBuf,
	transport: Transport,
	asked: Asked,
	admission: rooms_application::admission::Settings,
) -> Running {
	let (stop, stopped) = tokio::sync::oneshot::channel();
	let (ready, announced) = tokio::sync::oneshot::channel();
	let notices = Rc::new(RefCell::new(Vec::new()));
	let collected = notices.clone();
	let task = tokio::task::spawn_local(run(
		Config {
			admission,
			state: Some(state),
			transport,
			history: true,
			asked,
			trace_port: 0,
			trace_publish: None,
			trace_connect: None,
		},
		async {
			let _ = stopped.await;
		},
		|ready_now| {
			ready
				.send((
					ready_now.location.clone(),
					ready_now.capabilities.clone(),
					ready_now.trace.clone(),
				))
				.unwrap();
			Ok(())
		},
		Rc::new(move |notice: Notice| {
			if !matches!(notice, Notice::Admission(_)) {
				collected.borrow_mut().push(notice.to_string());
			}
		}),
	));
	let (location, capabilities, trace) = announced.await.expect("the directory became ready");
	Running {
		stop,
		task,
		location,
		capabilities,
		trace,
		notices,
	}
}

fn tcp() -> Transport {
	Transport::Tcp {
		bind: "127.0.0.1".into(),
		port: 0,
		announce: None,
	}
}

async fn runtime() -> Runtime {
	Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap()
}

/// A member that can be introduced to: it listens, so the directory's gift
/// of its inbox names a place the recipient can dial.
struct Member {
	listener: Rc<tcp::Server>,
	runtime: Runtime,
	accepting: tokio::task::JoinHandle<()>,
	stop_accepting: tokio::sync::oneshot::Sender<()>,
}

impl Member {
	async fn listen() -> Self {
		let listener = Rc::new(tcp::listen("127.0.0.1", 0, Default::default()).await.unwrap());
		let runtime =
			Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]).adopt_host(&listener.host()))
				.await
				.unwrap();
		let (stop_accepting, mut stopping) = tokio::sync::oneshot::channel();
		let accepting = {
			let listener = listener.clone();
			tokio::task::spawn_local(async move {
				let mut served = Vec::new();
				loop {
					let session = tokio::select! {
						_ = &mut stopping => break,
						accepted = listener.accept() => accepted.unwrap(),
					};
					served.push(tokio::task::spawn_local(async move {
						let _ = session.serve().await;
					}));
				}
				for task in served {
					task.abort();
				}
			})
		};
		Self {
			listener,
			runtime,
			accepting,
			stop_accepting,
		}
	}
	async fn connect(&self, directory: &str) -> Session {
		let session = self
			.runtime
			.connect(&glowcap::parse_locator(directory).unwrap(), ConnectOptions::default())
			.await
			.unwrap();
		session
			.set_exporter_locator(Some(&self.listener.locator().unwrap()))
			.unwrap();
		session
	}
	/// The listener goes first. The runtime adopted the listener's Host, so
	/// closing the runtime closes that Host and its loop.
	async fn close(self) {
		self.stop_accepting.send(()).unwrap();
		self.accepting.await.unwrap();
		self.listener.close().await.unwrap();
		self.runtime.close(PendingWork::Cancel).await.unwrap();
	}
}

fn closing_tolerated(result: glowcap::Result<()>) {
	if let Err(error) = result {
		assert!(
			rooms_platform::serving::left(&error),
			"closing the dialer failed: {error}"
		);
	}
}

#[tokio::test]
async fn rooms_server_registers_watches_introduces_and_relays_signaling_over_tcp() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(30), members())
				.await
				.expect("host directory service deadline");
		})
		.await;
}

async fn members() {
	let temp = Temp::new();
	let running = start(temp.0.clone(), tcp()).await;
	let dial = glowcap::parse_locator(&running.location).unwrap();
	let alice_member = Member::listen().await;
	let alice = Client::new(alice_member.connect(&running.location).await, HostPlatform);
	let bob_runtime = runtime().await;
	let bob = Client::new(
		bob_runtime.connect(&dial, ConnectOptions::default()).await.unwrap(),
		HostPlatform,
	);
	let (alice_dir, bob_dir) = (
		Directory::fetch(alice.clone()).await.unwrap(),
		Directory::fetch(bob.clone()).await.unwrap(),
	);
	assert_eq!(alice_dir.advertised_location().await.unwrap(), dial.designator);
	assert!(alice_dir.list(None).await.unwrap().rooms.is_empty());

	// Registration: the name is acknowledged and discoverable.
	let mut alice_name = alice_dir.registration();
	let alice_id = alice_name.register("Alice", "127.0.0.1:9", None).await.unwrap().id;
	let mut bob_name = bob_dir.registration();
	let bob_id = bob_name.register("Bob", "127.0.0.1:9", None).await.unwrap().id;
	assert_eq!(bob_dir.member_registration("alice").await.unwrap(), alice_id);
	let taken = bob_name.register("alice", "127.0.0.1:9", None).await.unwrap_err();
	assert!(taken.to_string().contains("nick-taken"), "{taken}");
	// A name capability carries the name to another connection.
	let voucher = alice_name.name_voucher().await.unwrap().expect("a voucher");
	let carol_runtime = runtime().await;
	let carol = Client::new(
		carol_runtime.connect(&dial, ConnectOptions::default()).await.unwrap(),
		HostPlatform,
	);
	let carol_dir = Directory::fetch(carol.clone()).await.unwrap();

	// Watching: the baseline lists both members; a change is told.
	let mut watch = bob_dir.watch().await.unwrap();
	let names: Vec<String> = watch
		.snapshot()
		.peers
		.iter()
		.map(|peer| peer.name.text().as_str().unwrap().to_owned())
		.collect();
	assert_eq!(names, ["Alice", "Bob"]);
	assert_eq!(watch.snapshot().omitted, 0);
	let mut carol_name = carol_dir.registration();
	let carol_id = carol_name.register("Carol", "127.0.0.1:9", None).await.unwrap().id;
	match watch.next().await.unwrap().expect("a registration event") {
		Event::Member { kind, peer, count } => {
			assert_eq!(kind, MemberChange::Registered);
			assert_eq!(peer.name.text().as_str(), Some("Carol"));
			assert_eq!(peer.registration_id.as_str(), Some(carol_id.as_str()));
			assert_eq!(count, 1);
		}
		other => panic!("unexpected watch event {other:?}"),
	}

	// Introduction: Bob asks for Alice; Alice is asked for an inbox, offers
	// one, and Bob reaches it over a handoff to Alice's own listener.
	let greetings = Rc::new(RefCell::new(Vec::<String>::new()));
	let heard = greetings.clone();
	let inbox = alice
		.session()
		.spawn_owned(move |verb, args| {
			let verb = verb.ok_or("fixture requires a method")?;
			heard.borrow_mut().push(format!(
				"{verb} {}",
				args.first().and_then(Argument::as_str).unwrap_or("")
			));
			Ok("alice".into())
		})
		.unwrap();
	let introducing = {
		let (bob_dir, alice_id) = (bob_dir.clone(), alice_id.clone());
		tokio::task::spawn_local(async move { bob_dir.introduce("Alice", Some(&alice_id)).await })
	};
	let asked = alice_name.next().await.unwrap().expect("an inbox request");
	assert_eq!(asked.kind, Kind::MintInboxFor);
	assert_eq!(asked.peer.text().as_str(), Some("Bob"));
	assert_eq!(asked.registration, bob_id);
	alice_dir
		.offer_inbox(
			"Bob",
			&bob_id,
			asked.opening.as_ref().unwrap().text().as_str().unwrap(),
			&inbox,
		)
		.await
		.unwrap();
	let introduction = introducing.await.unwrap().unwrap();
	assert_eq!(introduction.registration, alice_id);
	let answer = introduction
		.session()
		.send(&introduction.inbox, "hello", &["from bob".into()])
		.await
		.unwrap();
	assert_eq!(answer.as_str(), Some("alice"));
	assert_eq!(greetings.borrow().as_slice(), ["hello from bob"]);
	// A direct-route request reaches Alice's inbox once per window.
	bob_dir.request_direct("Alice", &alice_id).await.unwrap();
	bob_dir.request_direct("Alice", &alice_id).await.unwrap();
	let requested = alice_name.next().await.unwrap().expect("a direct request");
	assert_eq!(requested.kind, Kind::DirectRequested);
	assert_eq!(requested.registration, bob_id);

	let retired_carol_name = carol_name.take_name().unwrap().unwrap();
	// Signaling: Carol registers a webrtc designator, offers an inbox, and
	// Bob's offer reaches it; Carol's answer and both candidates cross back.
	let carol_id = carol_name
		.register("Carol", "ocapn://carol-designator.webrtc", None)
		.await
		.unwrap()
		.id;
	assert_eq!(carol_dir.member_registration("Carol").await.unwrap(), carol_id);
	// A re-registration on the same connection is a withdrawal and a fresh
	// filing, and the watcher hears both.
	for expected in [MemberChange::Unregistered, MemberChange::Registered] {
		match watch.next().await.unwrap().expect("a re-registration event") {
			Event::Member { kind, peer, .. } => {
				assert_eq!(kind, expected);
				assert_eq!(peer.name.text().as_str(), Some("Carol"));
			}
			other => panic!("unexpected watch event {other:?}"),
		}
	}
	let carol_name_ref = carol_name.take_name().unwrap().unwrap();
	let carol_route = rooms_glowcap::client::directory::signaling::Route::new(carol.clone(), carol_name_ref.clone());
	let bob_route =
		rooms_glowcap::client::directory::signaling::Route::new(bob.clone(), bob_name.take_name().unwrap().unwrap());
	for verb in [
		"offerSignaling",
		"signalOffer",
		"signalAnswer",
		"signalCandidate",
		"signalDone",
		"signalDecline",
	] {
		assert!(
			carol.session().send(&retired_carol_name, verb, &[]).await.is_err(),
			"retired name cannot signal through its successor: {verb}"
		);
	}
	let mut carol_signaling = carol_route.signaling_inbox().await.unwrap();
	let exchange = bob_route.signaling_exchange("carol-designator").unwrap();
	exchange.offer(&Description::parse("v=0 offer").unwrap()).unwrap();
	let Incoming::Offer { id, description, from } = carol_signaling.next().await.unwrap().expect("an offer") else {
		panic!("expected an offer");
	};
	assert_eq!(description.as_str(), "v=0 offer");
	// The directory names the offerer by the Host key it registered, and
	// Bob's address locator names none.
	assert!(from.is_none());
	carol_route
		.signal_answer(&id, &Description::parse("v=0 answer").unwrap())
		.unwrap();
	assert_eq!(exchange.answer().await.unwrap().as_str(), "v=0 answer");
	exchange
		.candidate(&rooms_application::signaling::Candidate::parse("candidate:bob").unwrap())
		.await
		.unwrap();
	let Incoming::Candidate { id: relayed, candidate } = carol_signaling.next().await.unwrap().expect("a candidate")
	else {
		panic!("expected a candidate");
	};
	assert_eq!(relayed, id);
	assert_eq!(candidate.as_str(), "candidate:bob");
	carol_route
		.signal_candidate(
			&id,
			&rooms_application::signaling::Candidate::parse("candidate:carol").unwrap(),
		)
		.unwrap();
	assert_eq!(
		exchange.next_candidate().await.unwrap().map(|c| c.as_str().to_owned()),
		Some("candidate:carol".into())
	);
	exchange.close().unwrap();
	// Carol declines a second offer, and Bob hears her reason at once.
	let declined = bob_route.signaling_exchange("carol-designator").unwrap();
	declined.offer(&Description::parse("v=0 offer").unwrap()).unwrap();
	let Incoming::Offer { id, .. } = carol_signaling.next().await.unwrap().expect("an offer") else {
		panic!("expected an offer");
	};
	carol_route
		.signal_decline(&id, &rooms_application::signaling::Reason::parse("busy").unwrap())
		.unwrap();
	let reason = declined.answer().await.unwrap_err();
	assert!(
		reason.to_string().contains("the member declined the offer: busy"),
		"{reason}"
	);
	declined.close().unwrap();
	// An offer to a designator nobody registered is refused as offline.
	let nowhere = bob_dir.signaling().signaling_exchange("nobody").unwrap();
	nowhere.offer(&Description::parse("v=0").unwrap()).unwrap();
	let refused = nowhere.answer().await.unwrap_err();
	assert!(refused.to_string().contains("peer-offline"), "{refused}");

	// Exact name retirement is idempotent and independent of transport close.
	carol.session().send(&carol_name_ref, "leave", &[]).await.unwrap();
	carol.session().send(&carol_name_ref, "leave", &[]).await.unwrap();
	assert!(carol.session().send(&carol_name_ref, "voucher", &[]).await.is_err());
	assert!(
		carol_route.offer_signaling(&inbox).await.is_err(),
		"retired exact name cannot file another signaling inbox"
	);
	// Carol leaving is told to the watcher, and her name frees.
	drop((carol_signaling, carol_name, carol_dir));
	closing_tolerated(carol.session().close(PendingWork::Cancel).await);
	match watch.next().await.unwrap().expect("an unregistration event") {
		Event::Member { kind, peer, count } => {
			assert_eq!(kind, MemberChange::Unregistered);
			assert_eq!(peer.name.text().as_str(), Some("Carol"));
			assert_eq!(count, 0);
		}
		other => panic!("unexpected watch event {other:?}"),
	}
	let offline = bob_dir.member_registration("Carol").await.unwrap_err();
	assert!(offline.to_string().contains("peer-offline"), "{offline}");
	// The voucher Alice minted carries her name onto Carol's old connection's
	// successor: a fresh session takes "Alice" and Alice's own row goes.
	let dave_runtime = runtime().await;
	let dave = Client::new(
		dave_runtime.connect(&dial, ConnectOptions::default()).await.unwrap(),
		HostPlatform,
	);
	let dave_dir = Directory::fetch(dave.clone()).await.unwrap();
	let mut dave_name = dave_dir.registration();
	let moved = dave_name
		.register("Alice", "127.0.0.1:9", Some(voucher))
		.await
		.unwrap()
		.id;
	assert_ne!(moved, alice_id);
	assert_eq!(bob_dir.member_registration("Alice").await.unwrap(), moved);

	drop((watch, bob_name, dave_name, alice_name, introduction, inbox));
	drop((alice_dir, bob_dir, dave_dir));
	closing_tolerated(alice.session().close(PendingWork::Cancel).await);
	closing_tolerated(bob.session().close(PendingWork::Cancel).await);
	closing_tolerated(dave.session().close(PendingWork::Cancel).await);
	running.stop.send(()).unwrap();
	running.task.await.unwrap().unwrap();
	assert!(running.notices.borrow().is_empty(), "{:?}", running.notices.borrow());
	alice_member.close().await;
	for runtime in [bob_runtime, carol_runtime, dave_runtime] {
		runtime.close(PendingWork::Cancel).await.unwrap();
	}
	drop(carol);
	drop(temp);
}

#[tokio::test]
async fn rooms_server_expires_an_unanswered_signaling_exchange() {
	tokio::task::LocalSet::new()
		.run_until(async {
			// Past the exchange timeout, so the paused clock reaches the
			// expiry before this deadline; only the setup spends real time.
			tokio::time::timeout(Duration::from_secs(90), expiry())
				.await
				.expect("host directory expiry deadline");
		})
		.await;
}

/// An offer whose target never answers is retired by the directory's own
/// clock, and the originator hears why on its reply. The clock is paused
/// once the offer is on its way, so the thirty seconds pass at once.
async fn expiry() {
	let temp = Temp::new();
	let running = start(temp.0.clone(), tcp()).await;
	let dial = glowcap::parse_locator(&running.location).unwrap();
	// One Host holds one session per partner, so each member is its own.
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
	bob_name.register("Bob", "127.0.0.1:9", None).await.unwrap();
	let mut carol_name = carol_dir.registration();
	carol_name
		.register("Carol", "ocapn://silent.webrtc", None)
		.await
		.unwrap();
	// Carol's signaling inbox takes every offer and answers none.
	let silent = carol.session().spawn_owned(|_, _| Ok(Argument::Void)).unwrap();
	carol_dir.signaling().offer_signaling(&silent).await.unwrap();
	let (heard, mut replies) = tokio::sync::mpsc::unbounded_channel();
	let reply = bob
		.session()
		.spawn_owned(move |verb, args| {
			let verb = verb.ok_or("fixture requires a method")?;
			let detail = args.first().and_then(Argument::as_str).unwrap_or("").to_owned();
			heard.send((verb.to_owned(), detail)).unwrap();
			Ok(Argument::Void)
		})
		.unwrap();
	bob.session()
		.send(
			bob_dir.reference(),
			rooms_application::signaling::OFFER,
			&["silent".into(), "v=0".into(), reply.clone().into()],
		)
		.await
		.unwrap();
	let (accepted, id) = replies.recv().await.unwrap();
	assert_eq!(accepted, "accepted");
	assert!(!id.is_empty());
	tokio::time::pause();
	let (rejected, reason) = replies.recv().await.unwrap();
	tokio::time::resume();
	assert_eq!(rejected, "reject");
	assert_eq!(reason, "signaling exchange timed out");
	drop((reply, silent, bob_name, carol_name, bob_dir, carol_dir));
	closing_tolerated(bob.session().close(PendingWork::Cancel).await);
	closing_tolerated(carol.session().close(PendingWork::Cancel).await);
	running.stop.send(()).unwrap();
	running.task.await.unwrap().unwrap();
	assert!(running.notices.borrow().is_empty(), "{:?}", running.notices.borrow());
	for runtime in [bob_runtime, carol_runtime] {
		runtime.close(PendingWork::Cancel).await.unwrap();
	}
}

#[tokio::test]
async fn rooms_server_keeps_its_identity_across_restart_over_iroh() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(30), restart())
				.await
				.expect("host directory restart deadline");
		})
		.await;
}

async fn restart() {
	let temp = Temp::new();
	let runtime = Runtime::open(RuntimeConfig::providers([iroh::provider(iroh::Config::new(
		iroh::Reachability::Direct,
	))]))
	.await
	.unwrap();
	let mut previous = None;
	for _ in 0..2 {
		let running = start(temp.0.clone(), Transport::Iroh(iroh::Reachability::Direct)).await;
		let locator = glowcap::parse_locator(&running.location).unwrap();
		if let Some(previous) = &previous {
			assert_eq!(&locator.designator, previous, "the identity seed names the same node");
		}
		previous = Some(locator.designator.clone());
		let session = runtime.connect(&locator, ConnectOptions::default()).await.unwrap();
		let client = Client::new(session, HostPlatform);
		let directory = Directory::fetch(client.clone()).await.unwrap();
		let mut name = directory.registration();
		// iroh proves the member's durable identity, so a locator that names
		// anything else is refused; the member's own node is accepted.
		let elsewhere = name.register("Alice", "127.0.0.1:9", None).await.unwrap_err();
		assert!(elsewhere.to_string().contains("not-your-locator"), "{elsewhere}");
		let own = format!("ocapn://{}.iroh", runtime.host().designator().unwrap());
		name.register("Alice", &own, None).await.unwrap();
		// A second process is refused custody while this one holds it.
		assert!(matches!(
			Peer::open(
				Config {
					admission: rooms_application::admission::Settings::defaults(8192, 1),
					state: Some(temp.0.clone()),
					transport: tcp(),
					history: false,
					asked: Default::default(),
					trace_port: 0,
					trace_publish: None,
					trace_connect: None,
				},
				Rc::new(|_| {})
			)
			.await,
			Err(Error::Storage(_))
		));
		drop((name, directory));
		closing_tolerated(client.session().close(PendingWork::Cancel).await);
		running.stop.send(()).unwrap();
		running.task.await.unwrap().unwrap();
		assert!(running.notices.borrow().is_empty(), "{:?}", running.notices.borrow());
	}
	let kept = std::fs::read_to_string(temp.0.join("rooms.json")).unwrap();
	assert!(kept.contains("\"identitySeed\""));
	runtime.close(PendingWork::Cancel).await.unwrap();
}
