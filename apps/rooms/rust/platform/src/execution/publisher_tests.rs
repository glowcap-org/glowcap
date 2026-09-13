//! Real Host aliases offered across registration churn and directory reconnect.
use super::HostPlatform;
use glowcap::{Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig, Session, tcp};
use rooms_application::{direct::publication as policy, directory::registration::Id};
use rooms_glowcap::client::{
	Client, Error,
	direct::publisher::{Entropy, Publisher},
	directory::Directory,
};
use std::{
	cell::{Cell, RefCell},
	future::Future,
	rc::Rc,
	time::Duration,
};
#[derive(Clone, Default)]
struct Platform(Rc<Cell<u8>>);
impl rooms_glowcap::client::Deadline for Platform {
	async fn within<T>(&self, ms: u64, work: impl Future<Output = T>) -> Option<T> {
		HostPlatform.within(ms, work).await
	}
}
impl Entropy for Platform {
	fn inbox_entropy(&self) -> Result<[u8; 32], Error> {
		let next = self.0.get();
		self.0.set(next + 1);
		Ok([next; 32])
	}
}
fn id(n: u32) -> Id {
	Id::parse(&format!("{n:08x}-1111-4111-8111-111111111111")).unwrap()
}
#[tokio::test]
async fn inbox_aliases_share_host_capacity_and_survive_reconnect_without_retargeting() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(10), scenario()).await.unwrap();
		})
		.await;
}
async fn scenario() {
	let server = tcp::listen("127.0.0.1", 0, Default::default()).await.unwrap();
	let arrivals = Rc::new(RefCell::new(Vec::<(glowcap::Ref, Session)>::new()));
	let offered = arrivals.clone();
	let delay = Rc::new(Cell::new(false));
	let delayed = delay.clone();
	let (tx, mut deferred) = tokio::sync::mpsc::channel(1);
	server
		.host()
		.publish_giftable("directory", move || {
			Box::new(move |verb, args| {
				assert_eq!(verb, "offerInbox");
				assert_eq!(args.len(), 3);
				if delayed.replace(false) {
					tx.try_send(
						glowcap::current_session()
							.unwrap()
							.unwrap()
							.host()
							.defer_turn()
							.unwrap(),
					)
					.unwrap();
				}
				let Argument::Reference(reference) = &args[2] else {
					panic!("inbox")
				};
				offered
					.borrow_mut()
					.push((reference.clone(), glowcap::current_session().unwrap().unwrap()));
				Ok(Argument::Void)
			})
		})
		.unwrap();
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let locator = server.locator().unwrap();
	let (caller, peer) = tokio::join!(runtime.connect(&locator, ConnectOptions::default()), server.accept());
	let peer = Rc::new(peer.unwrap().with_gc());
	let service = peer.clone();
	let serving = tokio::task::spawn_local(async move { service.serve().await });
	let platform = Platform::default();
	let client = Client::new(caller.unwrap(), platform.clone());
	let host = client.session().host();
	let directory = Directory::fetch(client.clone()).await.unwrap();
	let publisher = Publisher::with_limit(host.clone(), platform.clone(), 2).unwrap();
	assert!(matches!(
		Publisher::with_limit(host.clone(), HostPlatform, 1),
		Err(Error::Inbox(policy::Error::Limit))
	));
	let made = Rc::new(Cell::new(0));
	let count = made.clone();
	let one = publisher
		.offerer(move |peer, id| {
			assert_eq!(peer, "alice");
			assert_eq!(id, &super::publisher_tests::id(1));
			let generation = count.get() + 1;
			count.set(generation);
			Ok(Box::new(move |_, _| Ok(Argument::Integer(generation))))
		})
		.unwrap();
	let two = publisher
		.offerer(|_, _| Ok(Box::new(|_, _| Ok("two".into()))))
		.unwrap()
		.with_skip(|peer| peer == "self");
	two.offer(&directory, "self", &id(7)).await.unwrap();
	assert_eq!(publisher.held(), 0);
	// An unrelated Host alias collision releases only the provisional row.
	let mut scratch = policy::Ledger::new(2).unwrap();
	let scope = scratch.scope().unwrap();
	let collision = scratch.reserve(&scope, "alice", &id(1), [0; 32]).unwrap();
	host.publish_giftable(collision.alias(), || Box::new(|_, _| Ok("unrelated".into())))
		.unwrap();
	assert!(one.offer(&directory, "alice", &id(1)).await.is_err());
	assert_eq!(publisher.held(), 0);
	let unrelated = client.session().published_ref(collision.alias()).unwrap().unwrap();
	assert_eq!(
		client.session().send(&unrelated, "check", &[]).await.unwrap().as_str(),
		Some("unrelated")
	);
	host.unpublish_giftable(collision.alias()).unwrap();
	one.offer(&directory, "alice", &id(1)).await.unwrap();
	one.offer(&directory, "alice", &id(1)).await.unwrap();
	assert_eq!(publisher.held(), 1);
	assert_eq!(made.get(), 2);
	let old = {
		let rows = arrivals.borrow();
		assert_eq!(rows[0].0, rows[1].0);
		rows[0].0.clone()
	};
	assert_eq!(peer.send(&old, "check", &[]).await.unwrap().as_i64(), Some(2));
	delay.set(true);
	let pending_id = id(1);
	let mut pending = Box::pin(one.offer(&directory, "alice", &pending_id));
	let mut resolver =
		tokio::select! {r=deferred.recv()=>r.unwrap(),_=&mut pending=>panic!("offer acknowledged early")};
	drop(pending);
	assert_eq!(publisher.held(), 1);
	resolver.fulfill(&Argument::Void).unwrap();
	one.offer(&directory, "alice", &id(1)).await.unwrap();
	assert_eq!(made.get(), 2);
	assert!(matches!(
		one.offer(&directory, "bob", &id(1)).await,
		Err(Error::Inbox(policy::Error::Registration))
	));
	two.offer(&directory, "bob", &id(2)).await.unwrap();
	assert_eq!(Publisher::with_limit(host.clone(), HostPlatform, 2).unwrap().held(), 2);
	assert!(matches!(
		two.offer(&directory, "charlie", &id(3)).await,
		Err(Error::Inbox(policy::Error::Full))
	));
	one.forget(&id(1)).await.unwrap();
	assert_eq!(publisher.held(), 1);
	assert!(peer.send(&old, "check", &[]).await.is_err());
	one.offer(&directory, "alice", &id(1)).await.unwrap();
	assert_eq!(made.get(), 3);
	assert!(peer.send(&old, "check", &[]).await.is_err());
	let new = arrivals.borrow().last().unwrap().0.clone();
	assert_eq!(peer.send(&new, "check", &[]).await.unwrap().as_i64(), Some(3));
	client.session().close(PendingWork::Cancel).await.unwrap();
	serving.await.unwrap().unwrap();
	let (caller, peer2) = tokio::join!(runtime.connect(&locator, ConnectOptions::default()), server.accept());
	let peer2 = Rc::new(peer2.unwrap().with_gc());
	let service = peer2.clone();
	let serving = tokio::task::spawn_local(async move { service.serve().await });
	let reconnected = Client::new(caller.unwrap(), platform);
	let directory2 = Directory::fetch(reconnected.clone()).await.unwrap();
	one.offer(&directory2, "alice", &id(1)).await.unwrap();
	assert_eq!(made.get(), 3);
	assert_eq!(publisher.held(), 2);
	let new = arrivals.borrow().last().unwrap().0.clone();
	assert_eq!(peer2.send(&new, "check", &[]).await.unwrap().as_i64(), Some(3));
	drop(two);
	assert_eq!(publisher.held(), 2);
	publisher.reconcile().await.unwrap();
	assert_eq!(publisher.held(), 1);
	delay.set(true);
	let closing_id = id(1);
	let mut closing = Box::pin(one.offer(&directory2, "alice", &closing_id));
	let mut answer = tokio::select! {
		answer = deferred.recv() => answer.unwrap(),
		_ = &mut closing => panic!("closing offer answered early"),
	};
	one.close().await.unwrap();
	assert_eq!(publisher.held(), 0);
	assert!(peer2.send(&new, "check", &[]).await.is_err());
	answer.fulfill(&Argument::Void).unwrap();
	assert!(matches!(closing.await, Err(Error::Inbox(policy::Error::Closed))));
	assert!(one.offer(&directory2, "alice", &id(1)).await.is_err());
	peer2.close(PendingWork::Cancel).await.unwrap();
	drop((
		one,
		publisher,
		directory,
		directory2,
		client,
		reconnected,
		old,
		new,
		arrivals,
		unrelated,
	));
	runtime.close(PendingWork::Cancel).await.unwrap();
	server.host().unpublish_giftable("directory").unwrap();
	server.close().await.unwrap();
	server.host().close(PendingWork::Cancel).await.unwrap();
	serving.await.unwrap().unwrap();
}

#[tokio::test]
async fn inbox_retirement_yields_and_survives_cancellation_or_overlapping_cleanup() {
	tokio::task::LocalSet::new()
		.run_until(async {
			for overlapping in [false, true] {
				let host = glowcap::Host::from_seed([72; 32]).unwrap();
				let publisher = Publisher::with_limit(host.clone(), HostPlatform, 65).unwrap();
				let ledger = host
					.application_state(|| RefCell::new(policy::Ledger::new(65).unwrap()))
					.unwrap();
				let scope = ledger.borrow_mut().scope().unwrap();
				for index in 0..65 {
					let row = ledger
						.borrow_mut()
						.reserve(&scope, "alice", &id(index), [index as u8; 32])
						.unwrap();
					host.publish_giftable(row.alias(), || Box::new(|_, _| Ok(Argument::Void)))
						.unwrap();
					ledger.borrow_mut().published(&row).unwrap();
				}
				scope.close();
				let mut pending = Box::pin(publisher.reconcile());
				let mut cx = std::task::Context::from_waker(std::task::Waker::noop());
				assert!(pending.as_mut().poll(&mut cx).is_pending());
				assert_eq!(publisher.held(), 65);
				assert!(pending.as_mut().poll(&mut cx).is_pending());
				assert_eq!(publisher.held(), 1);
				if overlapping {
					publisher.reconcile().await.unwrap();
					let successor_scope = ledger.borrow_mut().scope().unwrap();
					let successor = ledger
						.borrow_mut()
						.reserve(&successor_scope, "alice", &id(128), [64; 32])
						.unwrap();
					host.publish_giftable(successor.alias(), || Box::new(|_, _| Ok("successor".into())))
						.unwrap();
					ledger.borrow_mut().published(&successor).unwrap();
					pending.await.unwrap();
					assert!(
						host.unpublish_giftable(successor.alias()).unwrap(),
						"an old batch must not unpublish a reused alias"
					);
					successor_scope.close();
					publisher.reconcile().await.unwrap();
				} else {
					drop(pending);
					publisher.reconcile().await.unwrap();
				}
				assert_eq!(publisher.held(), 0);
				host.close(PendingWork::Cancel).await.unwrap();
			}
		})
		.await;
}
