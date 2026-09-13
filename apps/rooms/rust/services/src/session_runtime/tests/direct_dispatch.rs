#[path = "direct_events.rs"]
mod direct_events;
#[path = "direct_media.rs"]
mod direct_media;
#[path = "direct_outgoing.rs"]
mod direct_outgoing;
#[path = "direct_recording.rs"]
mod direct_recording;
#[path = "direct_reopen.rs"]
mod direct_reopen;
#[path = "handed_rooms.rs"]
mod handed_rooms;
#[path = "room_links.rs"]
mod room_links;
use super::*;
use crate::session_runtime::{
	direct_dispatch::{DirectDispatcher, Effect, OPERATION_LIMIT, Outcomes, REQUEST_LIMIT},
	direct_events::{DirectEvents, Events},
	direct_routes::DirectRoutes,
};
use glowcap::Argument;
use rooms_glowcap::client::direct::publisher::Publisher;
use std::{
	future::Future,
	task::{Context, Waker},
};

struct Fixture {
	_temp: Temp,
	commands: SessionCommands,
	command_task: tokio::task::JoinHandle<Result<(), rooms_runtime::Error>>,
	runtime: DirectoryRuntime,
	directory_task: tokio::task::JoinHandle<Result<(), rooms_runtime::Error>>,
	inbox: Option<RegistrationInbox>,
	transport: Rc<Runtime>,
	publisher: Publisher<HostPlatform>,
	peer: peers::Peer,
	other: peers::Peer,
	arrival: peers::Arrival,
	other_arrival: peers::Arrival,
	arrivals: mpsc::Receiver<peers::Arrival>,
	routes: DirectRoutes,
	lines: DirectEvents,
	events: Events,
}
impl Fixture {
	async fn new(label: &str) -> Self {
		let temp = Temp(std::env::temp_dir().join(format!("rooms-dispatch-{label}-{}", std::process::id())));
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
		let (runtime, directories, events, inbox) = DirectoryRuntime::new(
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
		let peer = peers::Peer::start(14, tx.clone()).await;
		let other = peers::Peer::start(15, tx).await;
		for (index, peer) in [&peer, &other].into_iter().enumerate() {
			let locator = peer.locator();
			command(
				&commands,
				&format!("join-{index}"),
				Command::JoinDirectory,
				vec![
					json!({
						"id":CheckpointRoutes.locator_authority(&locator).unwrap(), "locator":locator,
						"nick":"alice", "home":index == 0, "standing":null
					})
					.to_string()
					.into(),
				],
			)
			.await;
		}
		let mut arrival = arrivals.recv().await.unwrap();
		let mut other_arrival = arrivals.recv().await.unwrap();
		if arrival.index != 14 {
			core::mem::swap(&mut arrival, &mut other_arrival);
		}
		arrival.ack().await;
		other_arrival.ack().await;
		until(&runtime, |r| r.rows().iter().all(|row| row.phase() == Phase::Connected)).await;
		let publisher = Publisher::new(transport.host().clone(), HostPlatform).unwrap();
		let routes = DirectRoutes::new();
		let (lines, events) = DirectEvents::new(rooms_platform::HostPlatform, &mut rooms_platform::OsEntropy).unwrap();
		Self {
			_temp: temp,
			commands,
			command_task,
			runtime,
			directory_task,
			inbox: Some(inbox),
			transport,
			publisher,
			peer,
			other,
			arrival,
			other_arrival,
			arrivals,
			routes,
			lines,
			events,
		}
	}
	fn dispatcher(&mut self) -> (DirectDispatcher, super::super::direct_dispatch::DirectWorker, Outcomes) {
		DirectDispatcher::new(
			self.runtime.clone(),
			self.inbox.take().unwrap(),
			self.publisher.clone(),
			self.routes.receiver(),
			Rc::new(|_| {}),
			super::route_openings::factory(self.lines.receiver(), self.routes.receiver()),
		)
	}
	async fn close(mut self) {
		self.routes.close();
		self.lines.close_files().await.unwrap();
		self.runtime.close().await.unwrap();
		self.directory_task.await.unwrap().unwrap();
		self.commands.close().await.unwrap();
		self.command_task.await.unwrap().unwrap();
		self.transport.close(PendingWork::Cancel).await.unwrap();
		self.peer.close().await;
		self.other.close().await;
	}
}
async fn deadline(work: impl Future<Output = ()>) {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(20), work)
				.await
				.expect("direct dispatcher deadline");
		})
		.await;
}
async fn published(outcomes: &mut Outcomes) -> AcceptedDirect {
	let outcome = outcomes.next().await.unwrap();
	let Effect::Published(context) = outcome.result.unwrap() else {
		panic!("publication outcome")
	};
	assert_eq!(outcome.work.directory(), context.directory());
	context
}

#[tokio::test]
async fn dispatcher_owns_independent_notices_shared_openings_and_pending_shutdown() {
	deadline(async {
		let mut fixture = Fixture::new("ownership").await;
		let (dispatch, worker, mut outcomes) = fixture.dispatcher();
		let task = tokio::task::spawn_local(worker.run());
		fixture.arrival.notify("directRequested").await;
		assert!(matches!(outcomes.next().await.unwrap().result, Ok(Effect::NotAccepted)));
		assert_eq!(fixture.peer.introductions.get(), 0);
		fixture.peer.delay_offer.set(true);
		fixture.arrival.notify("mintInboxFor").await;
		let mut held = fixture.peer.offers.recv().await.unwrap();
		fixture.other_arrival.notify("mintInboxFor").await;
		let other = published(&mut outcomes).await;
		let other_offer = fixture.other.offers.recv().await.unwrap();
		assert_eq!(
			other.directory().text().as_str(),
			Some(
				CheckpointRoutes
					.locator_authority(&fixture.other.locator())
					.unwrap()
					.as_str()
			)
		);
		assert!(
			Box::pin(outcomes.next())
				.as_mut()
				.poll(&mut Context::from_waker(Waker::noop()))
				.is_pending(),
			"the first publication still awaits acknowledgement"
		);
		assert_eq!(fixture.publisher.held(), 2);
		// Queue/active/result custody all spend one request budget. Dropping an
		// observation cannot refund work that the worker still owns.
		fixture.other.pending_introduction.set(true);
		let mut openings = Vec::new();
		for _ in 0..REQUEST_LIMIT {
			openings.push(dispatch.ensure(&other).unwrap());
		}
		drop(openings.pop());
		assert!(dispatch.ensure(&other).is_err());
		while fixture.other.introductions.get() == 0 {
			tokio::task::yield_now().await;
		}
		assert_eq!(fixture.other.introductions.get(), 1);
		fixture.other.pending_introduction.set(false);
		fixture.other_arrival.notify("introducible").await;
		for opening in openings {
			opening.wait().await.unwrap();
		}
		assert!(matches!(
			outcomes.next().await.unwrap().result,
			Ok(Effect::Introducible)
		));
		dispatch.ensure(&other).unwrap().wait().await.unwrap();
		fixture.routes.say(&other, "host dispatch").await.unwrap();
		let peers::DirectCall::Message {
			text,
			reply: Some(reply),
			session,
		} = fixture.other.direct_calls.recv().await.unwrap()
		else {
			panic!("direct message")
		};
		assert_eq!(text, "host dispatch");
		session
			.send(&reply, "dm", &["received through dispatch".into()])
			.await
			.unwrap();
		assert_eq!(
			fixture.events.next().await.unwrap().line().unwrap().text,
			"received through dispatch"
		);
		// A real remote refusal reaches the outcome consumer. Retrying reuses
		// its already-published alias and its durable accepted conversation.
		held.answer
			.as_mut()
			.unwrap()
			.break_with("fixture offer refused")
			.unwrap();
		let failed = outcomes.next().await.unwrap();
		assert!(
			failed
				.result
				.err()
				.unwrap()
				.to_string()
				.contains("fixture offer refused")
		);
		fixture.arrival.notify("mintInboxFor").await;
		let accepted = published(&mut outcomes).await;
		let retried = fixture.peer.offers.recv().await.unwrap();
		assert_eq!(held.inbox, retried.inbox);
		assert_eq!(fixture.publisher.held(), 2);
		// Completed request observations continue to spend their permits.
		let mut ready = Vec::new();
		for _ in 0..REQUEST_LIMIT {
			ready.push(dispatch.ensure(&other).unwrap());
		}
		ready.pop().unwrap().wait().await.unwrap();
		let restored = dispatch.ensure(&other).unwrap();
		assert!(dispatch.ensure(&other).is_err());
		restored.wait().await.unwrap();
		for opening in ready {
			opening.wait().await.unwrap();
		}
		let after_owner_close = dispatch.ensure(&other).unwrap();
		dispatch.ensure(&other).unwrap().wait().await.unwrap();
		let late = dispatch.ensure(&accepted).unwrap();
		dispatch.ensure(&accepted).unwrap().wait().await.unwrap();
		// Keep both a publication acknowledgement and a reciprocal announcement
		// pending while shutdown retires the worker's futures and actual tasks.
		let mut announcements = Vec::new();
		for _ in 0..OPERATION_LIMIT {
			fixture.other.delay_ready.set(true);
			fixture.other_arrival.notify("directRequested").await;
			let peers::DirectCall::Ready { reply, session } = fixture.other.direct_calls.recv().await.unwrap() else {
				panic!("reciprocal announcement")
			};
			announcements.push((reply, session, fixture.other.ready_answers.recv().await.unwrap()));
		}

		fixture.peer.delay_offer.set(true);
		fixture.arrival.notify("mintInboxFor").await;
		assert!(
			fixture.peer.offers.try_recv().is_err(),
			"a full worker does not start another offer"
		);
		let mut queued = Box::pin(dispatch.ensure(&other).unwrap().wait());
		assert!(
			queued
				.as_mut()
				.poll(&mut Context::from_waker(Waker::noop()))
				.is_pending()
		);
		let (ready, via, mut acknowledgement) = announcements.pop().unwrap();
		acknowledgement.fulfill(&Argument::Void).unwrap();
		assert!(matches!(
			outcomes.next().await.unwrap().result,
			Ok(Effect::RouteEstablished)
		));
		let mut pending = fixture.peer.offers.recv().await.unwrap();
		// Publication and requests compete fairly for released operation slots.
		// Release another slot if the waiting publication acquired the first.
		let (_, _, mut another) = announcements.pop().unwrap();
		another.fulfill(&Argument::Void).unwrap();
		assert!(matches!(
			outcomes.next().await.unwrap().result,
			Ok(Effect::RouteEstablished)
		));
		queued.await.unwrap();
		command(
			&fixture.commands,
			"close-direct",
			Command::CloseDirect,
			vec![accepted.conversation().text().clone()],
		)
		.await;
		assert!(
			late.wait().await.is_err(),
			"a completed opening cannot outlive its accepted authority"
		);
		while fixture.publisher.held() != 1 {
			tokio::task::yield_now().await;
		}
		assert!(
			pending.typing().await.is_err(),
			"committed close revokes a pending offer"
		);
		let mut closing = Box::pin(dispatch.close());
		assert!(
			closing
				.as_mut()
				.poll(&mut Context::from_waker(Waker::noop()))
				.is_pending()
		);
		drop(closing);
		assert!(dispatch.ensure(&other).is_err());
		dispatch.close().await.unwrap();
		task.await.unwrap().unwrap();
		assert!(after_owner_close.wait().await.is_err());
		let mut cancelled = 0;
		while let Some(outcome) = outcomes.next().await {
			assert!(outcome.result.is_err());
			cancelled += 1;
		}
		assert_eq!(cancelled, OPERATION_LIMIT - 1);
		assert_eq!(fixture.publisher.held(), 0);
		pending.answer.as_mut().unwrap().fulfill(&Argument::Void).unwrap();
		for (_, _, mut answer) in announcements {
			answer.fulfill(&Argument::Void).unwrap();
		}
		assert!(pending.typing().await.is_err());
		assert!(other_offer.typing().await.is_err());
		assert!(fixture.arrival.session.is_open() && fixture.other_arrival.session.is_open());
		// The parent owns completed routes and their actors independently.
		via.send(&ready, "dm", &["route survives dispatcher".into()])
			.await
			.unwrap();
		assert_eq!(
			fixture.events.next().await.unwrap().line().unwrap().text,
			"route survives dispatcher"
		);
		drop((held, retried, pending, other_offer, ready, reply, via, session));
		fixture.close().await;
	})
	.await;
}

#[tokio::test]
async fn dispatcher_observer_loss_is_reported_and_revokes_pending_publications() {
	deadline(async {
		let mut fixture = Fixture::new("observer").await;
		let (dispatch, worker, outcomes) = fixture.dispatcher();
		let task = tokio::task::spawn_local(worker.run());
		fixture.peer.delay_offer.set(true);
		fixture.arrival.notify("mintInboxFor").await;
		let mut pending = fixture.peer.offers.recv().await.unwrap();
		assert_eq!(fixture.publisher.held(), 1);
		drop(outcomes);
		assert!(
			task.await
				.unwrap()
				.unwrap_err()
				.to_string()
				.contains("outcome consumer")
		);
		assert!(
			dispatch
				.close()
				.await
				.unwrap_err()
				.to_string()
				.contains("outcome consumer")
		);
		assert_eq!(fixture.publisher.held(), 0);
		pending.answer.as_mut().unwrap().fulfill(&Argument::Void).unwrap();
		assert!(pending.typing().await.is_err());
		drop(pending);
		fixture.close().await;
	})
	.await;
}

#[tokio::test]
async fn dispatcher_outcomes_keep_notice_capacity_until_the_last_owner_releases_it() {
	deadline(async {
		let mut fixture = Fixture::new("outcomes").await;
		let (dispatch, worker, mut outcomes) = fixture.dispatcher();
		let task = tokio::task::spawn_local(worker.run());
		let mut held = Vec::new();
		for _ in 0..REGISTRATION_LIMIT {
			fixture.arrival.notify("introducible").await;
			let outcome = outcomes.next().await.unwrap();
			assert!(matches!(outcome.result, Ok(Effect::Introducible)));
			held.push(outcome.work.clone());
		}
		fixture.arrival.notify("introducible").await;
		until(&fixture.runtime, |r| r.rows()[0].phase() == Phase::Waiting).await;
		assert!(fixture.runtime.read().rows()[0].issue().unwrap().contains("budget"));
		assert_eq!(fixture.runtime.read().rows()[1].phase(), Phase::Connected);
		assert!(held.iter().all(|work| !work.current()));
		// Outcomes were dropped above; their retained work still owned every
		// permit. Releasing one now admits exactly one fresh-generation notice.
		held.pop();
		let resumed = fixture.arrivals.recv().await.unwrap();
		assert_eq!((resumed.index, resumed.connection), (14, 1));
		resumed.ack().await;
		until(&fixture.runtime, |r| r.rows()[0].phase() == Phase::Connected).await;
		resumed.notify("introducible").await;
		let fresh = outcomes.next().await.unwrap();
		assert!(fresh.work.current());
		assert!(matches!(fresh.result, Ok(Effect::Introducible)));
		drop((held, fresh));
		dispatch.close().await.unwrap();
		task.await.unwrap().unwrap();
		fixture.close().await;
	})
	.await;
}

#[tokio::test]
async fn dropping_dispatch_work_cannot_claim_observed_shutdown() {
	deadline(async {
		let mut fixture = Fixture::new("dropped").await;
		let (dispatch, worker, mut outcomes) = fixture.dispatcher();
		let task = tokio::task::spawn_local(worker.run());
		fixture.peer.delay_offer.set(true);
		fixture.arrival.notify("mintInboxFor").await;
		let mut pending = fixture.peer.offers.recv().await.unwrap();
		task.abort();
		assert!(task.await.unwrap_err().is_cancelled());
		assert!(
			dispatch
				.close()
				.await
				.unwrap_err()
				.to_string()
				.contains("without completing shutdown")
		);
		assert!(outcomes.next().await.is_none());
		// Drop revokes immediately; the Host-scoped publisher retains cleanup
		// custody and its charge until its parent explicitly reconciles it.
		assert_eq!(fixture.publisher.held(), 1);
		assert!(pending.typing().await.is_err());
		fixture.publisher.reconcile().await.unwrap();
		assert_eq!(fixture.publisher.held(), 0);
		pending.answer.as_mut().unwrap().fulfill(&Argument::Void).unwrap();
		drop(pending);
		fixture.close().await;
	})
	.await;
}
