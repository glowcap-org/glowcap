//! Rooms signaling over real capabilities, with controlled exchange milestones.
use super::HostPlatform;
use glowcap::{Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig, tcp};
use rooms_application::signaling::{self as signal, Candidate, Description, Id};
use rooms_glowcap::client::{Client, Error, Tasks, directory::Directory};
use std::{
	cell::{Cell, RefCell},
	future::{Future, poll_fn},
	rc::Rc,
	task::Poll,
	time::Duration,
};
#[derive(Clone, Default)]
struct Platform {
	expire: Rc<tokio::sync::Notify>,
}
impl rooms_glowcap::client::Deadline for Platform {
	async fn within<T>(&self, ms: u64, work: impl Future<Output = T>) -> Option<T> {
		tokio::select! { result=HostPlatform.within(ms,work)=>result, _=self.expire.notified(),if ms==signal::TIMEOUT_MS=>None }
	}
}
impl Tasks for Platform {
	type Task = super::HostTask;
	fn spawn(&self, work: impl Future<Output = ()> + 'static) -> Self::Task {
		HostPlatform.spawn(work)
	}
}
#[tokio::test]
async fn signaling_owns_both_milestones_and_bounds_callback_lifetimes() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(10), scenario())
				.await
				.expect("signaling scenario deadline");
		})
		.await;
}
async fn scenario() {
	let server = tcp::listen("127.0.0.1", 0, Default::default()).await.unwrap();
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let locator = server.locator().unwrap();
	let (connected, accepted) = tokio::join!(runtime.connect(&locator, ConnectOptions::default()), server.accept());
	let peer = Rc::new(accepted.unwrap());
	let serving_peer = peer.clone();
	let serving = tokio::task::spawn_local(async move { serving_peer.serve().await });
	let platform = Platform::default();
	let client = Client::new(connected.unwrap(), platform.clone());
	let replies = Rc::new(RefCell::new(Vec::<glowcap::Ref>::new()));
	let incoming = Rc::new(RefCell::new(None::<glowcap::Ref>));
	let done = Rc::new(Cell::new(0));
	let refuse_inbox = Rc::new(Cell::new(false));
	let refused = refuse_inbox.clone();
	let (tx, mut calls) = tokio::sync::mpsc::channel(16);
	let (service, targets, inbox, retired) = (peer.clone(), replies.clone(), incoming.clone(), done.clone());
	let root = peer
		.publish("directory", move |verb, args| match verb {
			"signalOffer" => {
				assert_eq!(args.len(), 3);
				assert_eq!(args[1].as_str(), Some("offer"));
				let Argument::Reference(reply) = &args[2] else {
					panic!("reply capability")
				};
				targets.borrow_mut().push(reply.clone());
				tx.try_send("offer").unwrap();
				Ok(Argument::Void)
			}
			"signalCandidate" => {
				assert_eq!(args[0].as_str(), Some("exchange"));
				assert_eq!(args[1].as_str(), Some("local ice"));
				tx.try_send("candidate").unwrap();
				Ok(Argument::Void)
			}
			"signalAnswer" => {
				assert_eq!(args[0].as_str(), Some("exchange"));
				assert_eq!(args[1].as_str(), Some("local answer"));
				tx.try_send("answer").unwrap();
				Ok(Argument::Void)
			}
			"signalDone" => {
				assert_eq!(args[0].as_str(), Some("exchange"));
				retired.set(retired.get() + 1);
				Ok(Argument::Void)
			}
			"offerSignaling" => {
				let [Argument::Reference(reply)] = args else {
					panic!("incoming signaling inbox")
				};
				*inbox.borrow_mut() = Some(reply.clone());
				if refused.get() {
					return Err("inbox refused".into());
				}
				service
					.tell(reply, "offer", &["exchange".into(), "remote offer".into()])
					.unwrap();
				Ok(Argument::Void)
			}
			"barrier" => Ok(Argument::Void),
			_ => Err("unknown signaling verb".into()),
		})
		.unwrap();
	let directory = Directory::fetch(client.clone()).await.unwrap();
	let offer = Description::parse("offer").unwrap();
	let ice = Candidate::parse("local ice").unwrap();
	let id = Id::parse("exchange").unwrap();
	let mut inbox = directory.signaling().signaling_inbox().await.unwrap();
	assert!(matches!(
		inbox.next().await.unwrap(),
		Some(signal::Incoming::Offer { .. })
	));
	let inbound = incoming.borrow().clone().unwrap();
	peer.send(&inbound, "candidate", &["exchange".into(), "remote ice".into()])
		.await
		.unwrap();
	assert!(matches!(
		inbox.next().await.unwrap(),
		Some(signal::Incoming::Candidate { .. })
	));
	directory
		.signaling()
		.signal_answer(&id, &Description::parse("local answer").unwrap())
		.unwrap();
	assert_eq!(calls.recv().await, Some("answer"));
	directory.signaling().signal_candidate(&id, &ice).unwrap();
	assert_eq!(calls.recv().await, Some("candidate"));
	let exchange = directory.signaling().signaling_exchange("peer").unwrap();
	assert!(matches!(
		directory.signaling().signaling_exchange("peer"),
		Err(Error::Signaling(signal::Error::Duplicate))
	));
	let mut early = Box::pin(exchange.candidate(&ice));
	tokio::select! {biased;_=&mut early=>panic!("candidate sent before acceptance"),_=tokio::task::yield_now()=>{}}
	exchange.offer(&offer).unwrap();
	assert_eq!(calls.recv().await, Some("offer"));
	assert!(matches!(
		exchange.offer(&offer),
		Err(Error::Signaling(signal::Error::Duplicate))
	));
	let reply = replies.borrow().last().unwrap().clone();
	peer.send(&reply, "answer", &["remote answer".into()]).await.unwrap();
	let mut answer = Box::pin(exchange.answer());
	tokio::select! {biased;_=&mut answer=>panic!("answer preceded acceptance"),_=tokio::task::yield_now()=>{}}
	drop(answer);
	peer.send(&reply, "accepted", &["exchange".into()]).await.unwrap();
	early.await.unwrap();
	assert_eq!(calls.recv().await, Some("candidate"));
	assert_eq!(exchange.answer().await.unwrap().as_str(), "remote answer");
	assert!(peer.send(&reply, "answer", &[inbound.clone().into()]).await.is_err());
	peer.send(&reply, "candidate", &["remote ice".into()]).await.unwrap();
	assert_eq!(exchange.next_candidate().await.unwrap().unwrap().as_str(), "remote ice");
	exchange.close().unwrap();
	exchange.close().unwrap();
	drop(exchange);
	client
		.session()
		.send(directory.reference(), "barrier", &[])
		.await
		.unwrap();
	assert_eq!(done.get(), 1);
	assert!(peer.send(&reply, "candidate", &["late".into()]).await.is_err());
	assert!(directory.signaling().take_signaling_failure().is_none());

	let timed = directory.signaling().signaling_exchange("peer").unwrap();
	timed.offer(&offer).unwrap();
	assert_eq!(calls.recv().await, Some("offer"));
	let timed_reply = replies.borrow().last().unwrap().clone();
	peer.send(&timed_reply, "answer", &["early answer".into()])
		.await
		.unwrap();
	client
		.session()
		.send(directory.reference(), "barrier", &[])
		.await
		.unwrap();
	platform.expire.notify_one();
	assert!(matches!(timed.answer().await, Err(Error::Timeout(_))));
	assert!(matches!(timed.next_candidate().await, Err(Error::Timeout(_))));
	peer.send(&timed_reply, "accepted", &["exchange".into()]).await.unwrap();
	assert!(matches!(timed.candidate(&ice).await, Err(Error::Timeout(_))));
	timed.close().unwrap();

	let crowded = directory.signaling().signaling_exchange("crowded").unwrap();
	let mut observers: Vec<_> = (0..signal::MAX_EVENTS)
		.map(|_| Box::pin(crowded.candidate(&ice)))
		.collect();
	poll_fn(|cx| {
		for observer in &mut observers {
			assert!(observer.as_mut().poll(cx).is_pending());
		}
		Poll::Ready(())
	})
	.await;
	crowded.offer(&offer).unwrap();
	assert_eq!(calls.recv().await, Some("offer"));
	assert!(matches!(
		crowded.answer().await,
		Err(Error::Signaling(signal::Error::Full))
	));
	let crowded_reply = replies.borrow().last().unwrap().clone();
	peer.send(&crowded_reply, "accepted", &["exchange".into()])
		.await
		.unwrap();
	peer.send(&crowded_reply, "answer", &["under pressure".into()])
		.await
		.unwrap();
	drop(observers);
	assert_eq!(crowded.answer().await.unwrap().as_str(), "under pressure");
	drop(crowded_reply);
	crowded.close().unwrap();
	let dropped = directory.signaling().signaling_exchange("dropped").unwrap();
	dropped.offer(&offer).unwrap();
	assert_eq!(calls.recv().await, Some("offer"));
	let dropped_reply = replies.borrow().last().unwrap().clone();
	peer.send(&dropped_reply, "accepted", &["exchange".into()])
		.await
		.unwrap();
	drop(dropped);
	client
		.session()
		.send(directory.reference(), "barrier", &[])
		.await
		.unwrap();
	assert_eq!(done.get(), 3);
	assert!(peer.send(&dropped_reply, "candidate", &["late".into()]).await.is_err());
	drop(dropped_reply);
	let other_root = peer.publish("other-directory", |_, _| Ok(Argument::Void)).unwrap();
	let other = Directory::new(client.clone(), client.session().fetch("other-directory").await.unwrap());
	let mut held = Vec::new();
	for i in 0..signal::MAX_EXCHANGES {
		held.push(directory.signaling().signaling_exchange(&format!("peer-{i}")).unwrap());
	}
	assert!(matches!(
		directory.signaling().signaling_exchange("overflow"),
		Err(Error::Signaling(signal::Error::Full))
	));
	let independent = other.signaling().signaling_exchange("peer-0").unwrap();
	drop((independent, other));
	peer.release(other_root).unwrap();
	drop(held);
	let slow = directory.signaling().signaling_exchange("slow").unwrap();
	slow.offer(&offer).unwrap();
	assert_eq!(calls.recv().await, Some("offer"));
	let slow_reply = replies.borrow().last().unwrap().clone();
	for _ in 0..signal::MAX_EVENTS {
		peer.send(&slow_reply, "candidate", &["ice".into()]).await.unwrap();
	}
	assert!(peer.send(&slow_reply, "candidate", &["ice".into()]).await.is_err());
	assert!(matches!(
		slow.next_candidate().await,
		Err(Error::Signaling(signal::Error::Overflow))
	));
	slow.close().unwrap();
	for _ in 0..signal::MAX_EVENTS {
		peer.send(&inbound, "candidate", &["exchange".into(), "ice".into()])
			.await
			.unwrap();
	}
	assert!(
		peer.send(&inbound, "candidate", &["exchange".into(), "ice".into()])
			.await
			.is_err()
	);
	assert!(matches!(
		inbox.next().await,
		Err(Error::Signaling(signal::Error::Overflow))
	));
	inbox.close();
	assert!(
		peer.send(&inbound, "offer", &["exchange".into(), "late".into()])
			.await
			.is_err()
	);
	refuse_inbox.set(true);
	assert!(directory.signaling().signaling_inbox().await.is_err());
	let refused = incoming.borrow().clone().unwrap();
	assert!(
		peer.send(&refused, "offer", &["exchange".into(), "late".into()])
			.await
			.is_err()
	);
	drop(refused);
	refuse_inbox.set(false);
	let mut live_inbox = directory.signaling().signaling_inbox().await.unwrap();
	live_inbox.next().await.unwrap();
	let live = directory.signaling().signaling_exchange("live").unwrap();
	live.offer(&offer).unwrap();
	assert_eq!(calls.recv().await, Some("offer"));
	client
		.session()
		.send(directory.reference(), "barrier", &[])
		.await
		.unwrap();
	client.session().close(PendingWork::Cancel).await.unwrap();
	assert!(matches!(
		live.answer().await,
		Err(Error::Signaling(signal::Error::Ended))
	));
	assert!(live.next_candidate().await.unwrap().is_none());
	assert!(live_inbox.next().await.unwrap().is_none());
	drop((
		inbox,
		live_inbox,
		live,
		timed,
		crowded,
		slow,
		directory,
		client,
		reply,
		timed_reply,
		slow_reply,
		inbound,
		replies,
		incoming,
	));
	peer.release(root).unwrap();
	peer.close(PendingWork::Cancel).await.unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
	server.close().await.unwrap();
	server.host().close(PendingWork::Cancel).await.unwrap();
	serving.await.unwrap().unwrap();
}
