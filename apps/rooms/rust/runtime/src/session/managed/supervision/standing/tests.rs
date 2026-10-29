//! A standing inspection consumes its supplied snapshot without another read or command.
use super::*;
use crate::session::managed::inbox;
use std::{num::NonZeroUsize, pin::Pin};

#[derive(Clone)]
struct Platform;
impl Tasks for Platform {
	type Task = Pin<Box<dyn Future<Output = ()>>>;
	fn spawn(&self, work: impl Future<Output = ()> + 'static) -> Self::Task {
		// Retain background owners without polling them. Only the explicit
		// reconciliation below can read this fixture's workspace.
		Box::pin(work)
	}
}
impl Deadline for Platform {
	fn monotonic_millis(&self) -> u64 {
		0
	}
	async fn within<T>(&self, ms: u64, work: impl Future<Output = T>) -> Option<T> {
		tokio::time::timeout(std::time::Duration::from_millis(ms), work)
			.await
			.ok()
	}
}
fn key<K>() -> custody::FieldKey<K> {
	custody::FieldKey::new(NonZeroU64::new(1).unwrap(), NonZeroU64::new(1).unwrap())
}
fn intent() -> workspace::Intent {
	let mut intent = workspace::Intent::empty();
	intent.directories = serde_json::from_value(serde_json::json!([{
		"id": "directory", "access": key::<custody::DirectoryAccess>(), "home": true,
		"nick": "peer", "nickAllocation": "exact", "standing": null
	}]))
	.unwrap();
	intent.conversations = serde_json::from_str(
		&serde_json::json!([{
			"kind": "room", "id": "conversation", "directory": "directory", "name": "room",
			"source": key::<custody::SessionAccess>(), "inbox": key::<custody::RoomInbox>(),
			"seat": key::<custody::RoomSeat>(), "reconnect": "manual", "standing": "away", "draft": ""
		}])
		.to_string(),
	)
	.unwrap();
	intent
}

#[tokio::test]
async fn unchanged_standing_and_admission_retries_preserve_selection_and_cancellation() {
	tokio::task::LocalSet::new().run_until(inspect()).await;
}
async fn inspect() {
	let host = glowcap::Host::from_seed([221; 32]).unwrap();
	let reads = Rc::new(Cell::new(0));
	let current_intent = Rc::new(std::cell::RefCell::new(intent()));
	let source = host
		.spawn({
			let reads = reads.clone();
			let current_intent = current_intent.clone();
			move |verb, args| {
				match verb {
					Some("snapshot") => assert!(args.is_empty()),
					Some("continue-workspace") => {
						assert_eq!(args.len(), 2);
						assert_eq!(args[1].as_i64(), Some(1), "only the private snapshot is permitted");
					}
					_ => panic!("unchanged standing cannot dispatch {verb:?}"),
				}
				reads.set(reads.get() + 1);
				Ok(Argument::List(vec![
					1.into(),
					serde_json::to_string(&*current_intent.borrow()).unwrap().into(),
				]))
			}
		})
		.unwrap();
	let owner = Session::new(host.clone(), Platform, NonZeroUsize::new(8192).unwrap());
	owner.bind(source.clone(), source.clone()).unwrap();
	let intent = intent();
	let workspace::Conversation::Room(room) = &intent.conversations.as_slice()[0] else {
		unreachable!()
	};
	let selected = workspace::InboxSelection::Room {
		id: room.id.clone(),
		directory: room.directory.clone(),
		nickname: workspace::RoomNickname::select(&intent, &room.directory).unwrap(),
		access: room.access,
		accepted: room.accepted,
		public_entry: room.public_entry.clone(),
		publication: room.publication.clone(),
		source: room.source.unwrap(),
		inbox: room.inbox.unwrap(),
	};
	let workspace = Workspace::local(host.clone(), Platform, source.clone());
	let inbox = inbox::open(
		&host,
		Platform,
		workspace.clone(),
		selected.clone(),
		owner.state.inboxes.clone(),
		|_, _, _, _| panic!("no incoming calls in a standing inspection"),
	)
	.unwrap();
	let (_stop, stopping) = watch::channel(false);
	let (_retry, retrying) = watch::channel(0);
	let mut worker = Worker {
		writer: owner.state.writer.clone(),
		budget: Rc::downgrade(&owner.state.memberships),
		lease: Some(Lease::Room(key())),
		inbox,
		selected,
		ready: watch::channel(None).0,
		finished: watch::channel(None).0,
		stopping,
		retrying,
		workspace,
		changes: owner.changes().unwrap(),
		installed: true,
		live: true,
		connection_expiry_pending: false,
		platform: Platform,
		retirement: None,
		recovery: owner.state.discovery_refresh.clone(),
		submission: None,
		rate_retry: rate_retry::Window::default(),
		standing: Standing {
			applied: "away".into(),
			..Default::default()
		},
	};
	let advice = rooms_application::admission::RetryAdvice {
		class: rooms_application::admission::Class::RoomTransient,
		retry_ms: 1000,
	};
	assert!(worker.rate_retry.delay(advice, 0).is_some());
	assert!(
		worker
			.apply_standing(
				"inspection",
				Some(Snapshot {
					revision: 1,
					intent: intent.clone()
				})
			)
			.await
			.unwrap()
	);
	assert_eq!(reads.get(), 0, "the caller already read the snapshot");
	assert!(
		worker.rate_retry.delay(advice, 60_000).is_some(),
		"confirmed standing must finish the previous incident's retry window"
	);
	assert!(worker.apply_standing("inspection", None).await.unwrap());
	assert_eq!(reads.get(), 1, "startup without a snapshot reads once");
	let mut retired = intent;
	retired.conversations = Default::default();
	assert!(
		!worker
			.apply_standing(
				"inspection",
				Some(Snapshot {
					revision: 2,
					intent: retired
				})
			)
			.await
			.unwrap()
	);
	assert_eq!(reads.get(), 1, "an obsolete selection cannot reacquire newer intent");
	// Exhausting the finite automatic window must retain this stage without
	// dispatch. Only an explicit retry of the same worker resumes its attempt.
	worker.rate_retry = rate_retry::Window::new("finite");
	let attempts = Rc::new(Cell::new(0));
	let counter = attempts.clone();
	{
		let waiting = worker.stage(|| {
			counter.set(counter.get() + 1);
			let result = if counter.get() == 1 {
				Err(loam::refusal("rate-limited: retry-after-ms=60000; scope=join"))
			} else {
				Ok(())
			};
			async move { result }
		});
		tokio::pin!(waiting);
		assert!(
			core::future::poll_fn(|cx| core::task::Poll::Ready(waiting.as_mut().poll(cx)))
				.await
				.is_pending()
		);
		assert_eq!(attempts.get(), 1);
		_retry.send_replace(1);
		assert!(waiting.await.unwrap().is_some());
		assert_eq!(attempts.get(), 2);
	}
	// The existing stage is the only retry owner. A changed exact selection
	// during its wait must prevent another attempt even without a stop signal.
	let attempts = Rc::new(Cell::new(0));
	let counter = attempts.clone();
	{
		let waiting = worker.stage(|| {
			counter.set(counter.get() + 1);
			async { Err::<(), _>(loam::refusal("rate-limited: retry-after-ms=1; scope=join")) }
		});
		tokio::pin!(waiting);
		assert!(
			core::future::poll_fn(|cx| core::task::Poll::Ready(waiting.as_mut().poll(cx)))
				.await
				.is_pending()
		);
		current_intent.borrow_mut().conversations = Default::default();
		assert!(waiting.await.unwrap().is_none());
		assert_eq!(attempts.get(), 1, "selection removal dispatched a later attempt");
	}

	*current_intent.borrow_mut() = self::intent();
	let counter = attempts.clone();
	{
		let waiting = worker.stage(|| {
			counter.set(counter.get() + 1);
			async { Err::<(), _>(loam::refusal("rate-limited: retry-after-ms=1; scope=join")) }
		});
		tokio::pin!(waiting);
		assert!(
			core::future::poll_fn(|cx| core::task::Poll::Ready(waiting.as_mut().poll(cx)))
				.await
				.is_pending()
		);
		_stop.send_replace(true);
		assert!(waiting.await.unwrap().is_none());
		assert_eq!(attempts.get(), 2, "cancellation dispatched a later attempt");
	}
	drop((worker, owner, source));
	host.close(glowcap::PendingWork::Cancel).await.unwrap();
}
