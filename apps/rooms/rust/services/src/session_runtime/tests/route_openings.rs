use super::*;
use crate::session_runtime::{
	direct_events::{DirectEvents, EventReceiver, Events},
	direct_publications::DirectPublications,
	direct_routes::{DirectRoutes, RouteReceiver},
	route_openings::{RouteOpenings, WAITER_LIMIT},
};
use glowcap::{Argument, Behavior};
use rooms_glowcap::client::{
	Client, Error,
	direct::{publisher::Publisher, receiver},
};
use std::{
	future::Future,
	task::{Context, Waker},
};

struct Owner {
	routes: DirectRoutes,
	lines: DirectEvents,
	events: Events,
	publications: DirectPublications,
	openings: RouteOpenings,
}
pub(super) fn factory(
	lines: EventReceiver,
	routes: RouteReceiver,
) -> impl FnMut(AcceptedDirect) -> Result<Behavior, Error> {
	move |context| {
		let (lines, routes) = (lines.clone(), routes.clone());
		Ok(Box::new(receiver(move |notice, session| {
			use rooms_application::direct::Notice;
			let client = Client::new(session, HostPlatform);
			let answer = || -> Result<Argument, rooms_runtime::Error> {
				match notice {
					Notice::Message {
						text,
						attachments,
						reply,
						previews,
					} => {
						if let Some(reply) = reply {
							routes.adopt(&context, client.clone(), reply)?;
						}
						lines
							.post_with_previews(context.clone(), client.session(), text, previews, attachments)
							.map(Argument::Reference)
					}
					Notice::Ready(reply) => {
						routes.adopt(&context, client, reply)?;
						Ok(Argument::Void)
					}
					Notice::Typing(on) => {
						lines.typing(context.clone(), on)?;
						Ok(Argument::Void)
					}
					_ => Err(rooms_runtime::Error::refused(
						"the fixture does not receive room or archive handoffs",
					)),
				}
			};
			answer().map_err(rooms_runtime::Error::into_refusal)
		})))
	}
}
impl Owner {
	fn new(runtime: &DirectoryRuntime, publisher: &Publisher<HostPlatform>) -> Self {
		let routes = DirectRoutes::new();
		let (lines, events) = DirectEvents::new(rooms_platform::HostPlatform, &mut rooms_platform::OsEntropy).unwrap();
		let publications = DirectPublications::new(publisher.clone(), factory(lines.receiver(), routes.receiver()));
		let openings = RouteOpenings::new(
			runtime.clone(),
			routes.receiver(),
			factory(lines.receiver(), routes.receiver()),
		);
		Self {
			routes,
			lines,
			events,
			publications,
			openings,
		}
	}
	async fn close(&mut self) {
		self.openings.close().await.unwrap();
		self.publications.close().await.unwrap();
		self.lines.close_files().await.unwrap();
		self.routes.close();
	}
}
async fn called(peer: &peers::Peer, before: usize) {
	while peer.introductions.get() == before {
		tokio::task::yield_now().await;
	}
}

#[tokio::test]
async fn route_openings_share_work_receive_reciprocals_and_retire_owned_tasks() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(20), scenario())
				.await
				.expect("route opening deadline");
		})
		.await;
}
async fn scenario() {
	let temp = Temp(std::env::temp_dir().join(format!("rooms-openings-{}", std::process::id())));
	std::fs::create_dir(&temp.0).unwrap();
	let documents = SessionDocuments::open(&temp.0).await.unwrap().into_owners();
	drop((documents.grants, documents.bridge_secrets));
	let (commands, worker) = SessionCommands::open(documents.state, rooms_platform::HostPlatform)
		.await
		.unwrap();
	let transport = Rc::new(
		Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
			.await
			.unwrap(),
	);
	let (runtime, directories, events, mut inbox) = DirectoryRuntime::new(
		transport.clone(),
		commands.clone(),
		"ocapn://member.id".into(),
		rooms_platform::HostPlatform,
		rooms_platform::OsEntropy,
	)
	.unwrap();
	let command_task = tokio::task::spawn_local(worker.run(events));
	let directory_task = tokio::task::spawn_local(directories.run());
	let (tx, mut arrivals) = mpsc::channel(4);
	let mut peer = peers::Peer::start(12, tx.clone()).await;
	let mut other = peers::Peer::start(13, tx).await;
	let locator = peer.locator();
	command(
		&commands,
		"join",
		Command::JoinDirectory,
		vec![
			json!({
				"id":CheckpointRoutes.locator_authority(&locator).unwrap(), "locator":locator,
				"nick":"alice", "home":true, "standing":null
			})
			.to_string()
			.into(),
		],
	)
	.await;
	let arrival = arrivals.recv().await.unwrap();
	arrival.ack().await;
	let locator = other.locator();
	command(
		&commands,
		"join-other",
		Command::JoinDirectory,
		vec![
			json!({
				"id":CheckpointRoutes.locator_authority(&locator).unwrap(), "locator":locator,
				"nick":"alice", "home":false, "standing":null
			})
			.to_string()
			.into(),
		],
	)
	.await;
	let other_arrival = arrivals.recv().await.unwrap();
	other_arrival.ack().await;
	until(&runtime, |r| r.rows().iter().all(|row| row.phase() == Phase::Connected)).await;
	let publisher = Publisher::new(transport.host().clone(), HostPlatform).unwrap();
	let mut owner = Owner::new(&runtime, &publisher);
	arrival.notify("directRequested").await;
	let requested = inbox.next().await.unwrap();
	assert!(
		owner.openings.requested(&requested).unwrap().is_none(),
		"reverse requests never accept a new conversation"
	);
	assert_eq!(peer.introductions.get(), 0);
	arrival.notify("mintInboxFor").await;
	let work = inbox.next().await.unwrap();
	let accepted = owner.publications.offer(&runtime, &work).await.unwrap();
	let offer = peer.offers.recv().await.unwrap();
	other_arrival.notify("mintInboxFor").await;
	let other_work = inbox.next().await.unwrap();
	let other_accepted = owner.publications.offer(&runtime, &other_work).await.unwrap();
	let other_offer = other.offers.recv().await.unwrap();
	other.pending_introduction.set(true);
	let blocked = owner.openings.ensure(&other_accepted).unwrap();
	let cancelled = owner.openings.ensure(&accepted).unwrap();
	let waiting = owner.openings.ensure(&accepted).unwrap();
	drop(cancelled);
	waiting.wait().await.unwrap();
	called(&other, 0).await;
	assert_eq!(peer.introductions.get(), 1);
	owner.routes.say(&accepted, "opened").await.unwrap();
	let peers::DirectCall::Message {
		text,
		reply: Some(reply),
		session,
	} = peer.direct_calls.recv().await.unwrap()
	else {
		panic!("opened direct message")
	};
	assert_eq!(text, "opened");
	session.send(&reply, "dm", &["callback".into()]).await.unwrap();
	assert_eq!(owner.events.next().await.unwrap().line().unwrap().text, "callback");
	let mut waiters = Vec::new();
	// The other directory's pending waiter also spends this owner's budget.
	for _ in 1..WAITER_LIMIT {
		waiters.push(owner.openings.ensure(&accepted).unwrap());
	}
	assert!(owner.openings.ensure(&accepted).is_err());
	waiters.pop();
	owner.openings.ensure(&accepted).unwrap().wait().await.unwrap();
	drop(waiters);
	owner
		.openings
		.requested(&requested)
		.unwrap()
		.unwrap()
		.establish()
		.await
		.unwrap();
	let peers::DirectCall::Ready {
		reply: ready,
		session: via,
	} = peer.direct_calls.recv().await.unwrap()
	else {
		panic!("reverse carrier announcement")
	};
	via.send(&ready, "dm", &["ready reply".into()]).await.unwrap();
	assert_eq!(owner.events.next().await.unwrap().line().unwrap().text, "ready reply");
	owner.openings.close().await.unwrap();
	// Completed routes and reply actors belong to the route owner, not the
	// attempt that produced them. Closing only attempts leaves them available.
	via.send(&ready, "dm", &["after opening owner close".into()])
		.await
		.unwrap();
	assert_eq!(
		owner.events.next().await.unwrap().line().unwrap().text,
		"after opening owner close"
	);
	owner.close().await;
	assert!(
		blocked.wait().await.is_err(),
		"closing observes the independent pending opening"
	);
	let retired = session
		.send(&reply, "dm", &["retired".into()])
		.await
		.unwrap_err()
		.to_string();
	assert_eq!(
		rooms_application::failure::Failure::parse(&retired).map(|f| f.code),
		Some(rooms_application::failure::FailureCode::DirectNotAccepted)
	);
	drop((offer, other_offer, owner));

	// A pending normal introduction is superseded by a real reciprocal inbox.
	let mut owner = Owner::new(&runtime, &publisher);
	owner.publications.offer(&runtime, &work).await.unwrap();
	let offer = peer.offers.recv().await.unwrap();
	peer.pending_introduction.set(true);
	let before = peer.introductions.get();
	let waiting = owner.openings.ensure(&accepted).unwrap();
	called(&peer, before).await;
	let mut reciprocal = super::routes::install(&offer).await;
	waiting.wait().await.unwrap();
	assert!(
		peer.direct_calls.try_recv().is_err(),
		"an incoming route avoids reversal"
	);
	owner.routes.say(&accepted, "incoming won").await.unwrap();
	assert_eq!(reciprocal.messages.recv().await.unwrap(), "incoming won");
	owner.close().await;
	peer.pending_introduction.set(false);
	drop((owner, offer, reciprocal));

	// An ordinary failure asks once for the reciprocal route, which wakes all
	// waiters. A reverse request's own failure must not ask for another reversal.
	peer.fail_introduction.set(true);
	let mut owner = Owner::new(&runtime, &publisher);
	owner.publications.offer(&runtime, &work).await.unwrap();
	let offer = peer.offers.recv().await.unwrap();
	let one = owner.openings.ensure(&accepted).unwrap();
	let two = owner.openings.ensure(&accepted).unwrap();
	assert!(matches!(
		peer.direct_calls.recv().await.unwrap(),
		peers::DirectCall::Requested
	));
	let reciprocal = super::routes::install(&offer).await;
	one.wait().await.unwrap();
	two.wait().await.unwrap();
	owner.close().await;
	drop((owner, offer, reciprocal));
	let mut owner = Owner::new(&runtime, &publisher);
	assert!(
		owner
			.openings
			.requested(&requested)
			.unwrap()
			.unwrap()
			.establish()
			.await
			.is_err()
	);
	assert!(peer.direct_calls.try_recv().is_err());
	owner.close().await;
	timeout_and_retry(&runtime, &publisher, &accepted, &mut peer).await;
	local_refusal(&runtime, &publisher, &accepted, &work, &mut peer).await;
	factory_retirement(&runtime, &accepted).await;
	opening_pressure(&runtime, &arrival, &mut inbox).await;

	// A cancelled close retains task handles so the next close can observe
	// their real completion. The connection remains usable by sibling owners.
	peer.fail_introduction.set(false);
	peer.pending_introduction.set(true);
	let mut owner = Owner::new(&runtime, &publisher);
	let before = peer.introductions.get();
	let waiting = owner.openings.ensure(&accepted).unwrap();
	called(&peer, before).await;
	let mut closing = Box::pin(owner.openings.close());
	assert!(
		closing
			.as_mut()
			.poll(&mut Context::from_waker(Waker::noop()))
			.is_pending()
	);
	drop(closing);
	assert!(waiting.wait().await.is_err());
	owner.close().await;
	assert!(arrival.session.is_open());

	let mut owner = Owner::new(&runtime, &publisher);
	let before = peer.introductions.get();
	let waiting = owner.openings.ensure(&accepted).unwrap();
	called(&peer, before).await;
	command(
		&commands,
		"close-direct",
		Command::CloseDirect,
		vec![accepted.conversation().text().clone()],
	)
	.await;
	assert!(waiting.wait().await.is_err(), "committed retirement wakes the opening");
	assert!(owner.openings.ensure(&accepted).is_err());
	owner.close().await;
	runtime.close().await.unwrap();
	directory_task.await.unwrap().unwrap();
	commands.close().await.unwrap();
	command_task.await.unwrap().unwrap();
	drop((owner, publisher));
	transport.close(PendingWork::Cancel).await.unwrap();
	peer.close().await;
	other.close().await;
}

async fn timeout_and_retry(
	runtime: &DirectoryRuntime,
	publisher: &Publisher<HostPlatform>,
	accepted: &AcceptedDirect,
	peer: &mut peers::Peer,
) {
	let mut owner = Owner::new(runtime, publisher);
	let waiting = owner.openings.ensure(accepted).unwrap();
	assert!(matches!(
		peer.direct_calls.recv().await.unwrap(),
		peers::DirectCall::Requested
	));
	// The barrier round trip follows the request acknowledgement on this wire.
	// Advance only after the opening can enter its reciprocal wait.
	runtime
		.direct_directory(accepted)
		.unwrap()
		.member_registration("bob")
		.await
		.unwrap();
	tokio::task::yield_now().await;
	tokio::time::pause();
	tokio::time::advance(Duration::from_millis(
		rooms_application::direct::RECIPROCAL_ROUTE_TIMEOUT_MS + 1,
	))
	.await;
	let error = waiting.wait().await.unwrap_err().to_string();
	tokio::time::resume();
	assert!(
		error.contains("did not establish the requested reciprocal route"),
		"{error}"
	);
	peer.fail_introduction.set(false);
	owner.openings.ensure(accepted).unwrap().wait().await.unwrap();
	assert!(
		owner.routes.live(accepted),
		"a timed out attempt does not prevent retry"
	);
	owner.close().await;
}

async fn factory_retirement(runtime: &DirectoryRuntime, accepted: &AcceptedDirect) {
	let routes = Rc::new(DirectRoutes::new());
	let retiring = routes.clone();
	let mut openings = RouteOpenings::new(runtime.clone(), routes.receiver(), move |_| {
		retiring.close();
		Ok(Box::new(|_, _| {
			panic!("a retired opening's reply actor must not be published")
		}))
	});
	assert!(openings.ensure(accepted).unwrap().wait().await.is_err());
	assert!(!routes.live(accepted));
	openings.close().await.unwrap();
}

async fn local_refusal(
	runtime: &DirectoryRuntime,
	publisher: &Publisher<HostPlatform>,
	accepted: &AcceptedDirect,
	work: &RegistrationWork,
	peer: &mut peers::Peer,
) {
	let mut owner = Owner::new(runtime, publisher);
	owner.publications.offer(runtime, work).await.unwrap();
	let offer = peer.offers.recv().await.unwrap();
	owner.openings = RouteOpenings::new(runtime.clone(), owner.routes.receiver(), |_| {
		Err(rooms_application::direct::Error::Ended.into())
	});
	let waiting = owner.openings.ensure(accepted).unwrap();
	assert!(matches!(
		peer.direct_calls.recv().await.unwrap(),
		peers::DirectCall::Requested
	));
	let reciprocal = super::routes::install(&offer).await;
	waiting.wait().await.unwrap();
	assert!(owner.routes.live(accepted));
	owner.close().await;
	drop(reciprocal);
}

async fn opening_pressure(runtime: &DirectoryRuntime, arrival: &peers::Arrival, inbox: &mut RegistrationInbox) {
	use crate::session_runtime::route_openings::OPENING_LIMIT;
	let mut accepted = Vec::new();
	for index in 0..=OPENING_LIMIT {
		arrival
			.notify_registration("mintInboxFor", &format!("{index:08x}-1111-4111-8111-111111111111"))
			.await;
		let work = inbox.next().await.unwrap();
		accepted.push(runtime.accept_direct(&work).await.unwrap());
	}
	let routes = DirectRoutes::new();
	let mut openings = RouteOpenings::new(runtime.clone(), routes.receiver(), |_| panic!("cancelled factory"));
	let mut waiters = Vec::new();
	for context in &accepted[..OPENING_LIMIT] {
		waiters.push(openings.ensure(context).unwrap());
	}
	assert!(openings.ensure(&accepted[OPENING_LIMIT]).is_err());
	// Sharing admitted work is still possible at the distinct-opening limit.
	waiters.push(openings.ensure(&accepted[0]).unwrap());
	openings.close().await.unwrap();
	for waiter in waiters {
		assert!(waiter.wait().await.is_err());
	}
	assert!(arrival.session.is_open());
}
