use super::*;
use crate::session_runtime::{direct_events::Events, direct_routes::DirectRoutes};
use glowcap::{Argument, Ref, Resolver};
use std::cell::Cell;

pub(super) struct Reciprocal {
	pub messages: mpsc::Receiver<String>,
	answers: mpsc::Receiver<Resolver>,
	reply: Ref,
	line: Ref,
	edits: Rc<Cell<usize>>,
}
pub(super) async fn install(offer: &peers::Offer) -> Reciprocal {
	let (sent, messages) = mpsc::channel(8);
	let (waiting, answers) = mpsc::channel(2);
	let edits = Rc::new(Cell::new(0));
	let changes = edits.clone();
	let line = offer
		.session
		.spawn_owned(move |verb, _| {
			assert_eq!(verb, "edit");
			changes.set(changes.get() + 1);
			Ok(Argument::Void)
		})
		.unwrap();
	let posted = line.clone();
	let reply = offer
		.session
		.spawn_owned(move |verb, args| {
			assert_eq!(verb, "dm");
			let text = args[0].as_str().unwrap();
			sent.try_send(text.to_owned()).unwrap();
			if text == "pending" {
				waiting
					.try_send(
						glowcap::current_session()
							.unwrap()
							.unwrap()
							.host()
							.defer_turn()
							.unwrap(),
					)
					.unwrap();
				Ok(Argument::Void)
			} else {
				Ok(posted.clone().into())
			}
		})
		.unwrap();
	offer
		.session
		.send(&offer.inbox, "directReady", &[reply.clone().into()])
		.await
		.unwrap();
	Reciprocal {
		messages,
		answers,
		reply,
		line,
		edits,
	}
}
pub(super) async fn exercise(
	routes: &DirectRoutes,
	context: &AcceptedDirect,
	offer: &peers::Offer,
	events: &mut Events,
) -> Reciprocal {
	replacement(context).await;
	assert!(!routes.live(context));
	let mut peer = install(offer).await;
	assert!(routes.live(context));
	// A fresh incoming occurrence of the same reference is idempotent. A fresh
	// capability on the same pooled session replaces it because the partner can
	// reopen independently while this local context remains current.
	offer
		.session
		.send(&offer.inbox, "directReady", &[peer.reply.clone().into()])
		.await
		.unwrap();
	let (replacement_tx, mut replacement_messages) = mpsc::channel(2);
	let replacement_line = peer.line.clone();
	let replacement = offer
		.session
		.spawn_owned(move |verb, args| {
			assert_eq!(verb, "dm");
			replacement_tx.try_send(args[0].as_str().unwrap().to_owned()).unwrap();
			Ok(replacement_line.clone().into())
		})
		.unwrap();
	let mut route_changes = routes.changes();
	offer
		.session
		.send(&offer.inbox, "directReady", &[replacement.into()])
		.await
		.unwrap();
	tokio::time::timeout(std::time::Duration::from_secs(2), route_changes.changed())
		.await
		.expect("replacement route was installed")
		.unwrap();
	let posted = routes.say(context, "reciprocal").await.unwrap().unwrap();
	assert_eq!(replacement_messages.recv().await.unwrap(), "reciprocal");
	posted.edit("changed").await.unwrap();
	assert_eq!(peer.edits.get(), 1);
	offer
		.session
		.send(&offer.inbox, "dm", &["inline reply".into(), peer.reply.clone().into()])
		.await
		.unwrap();
	assert_eq!(events.next().await.unwrap().line().unwrap().text, "inline reply");
	// An inline reply occurrence is route evidence too, so it restores the
	// original reciprocal capability before the next send.
	routes.say(context, "after inline").await.unwrap();
	assert_eq!(peer.messages.recv().await.unwrap(), "after inline");
	peer
}

async fn replacement(context: &AcceptedDirect) {
	use crate::{client::Deadline, session_runtime::direct_routes::Adoption};
	use rooms_glowcap::client::Client;
	let server = tcp::listen("127.0.0.1", 0, Default::default()).await.unwrap();
	let first = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let second = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let locator = server.locator().unwrap();
	let (a, near_a) = tokio::join!(first.connect(&locator, Default::default()), server.accept());
	let (b, near_b) = tokio::join!(second.connect(&locator, Default::default()), server.accept());
	let (a, b) = (Client::new(a.unwrap(), Deadline), Client::new(b.unwrap(), Deadline));
	let (near_a, near_b) = (Rc::new(near_a.unwrap().with_gc()), Rc::new(near_b.unwrap().with_gc()));
	let called = Rc::new(Cell::new(0));
	let calls = called.clone();
	server
		.host()
		.publish_giftable("reply", move || {
			Box::new(move |verb, _| {
				assert_eq!(verb, "dm");
				calls.set(calls.get() + 1);
				Ok(Argument::Void)
			})
		})
		.unwrap();
	let serve_a = {
		let session = near_a.clone();
		tokio::task::spawn_local(async move { session.serve().await })
	};
	let serve_b = {
		let session = near_b.clone();
		tokio::task::spawn_local(async move { session.serve().await })
	};
	let target_a = a.session().fetch("reply").await.unwrap();
	let target_b = b.session().fetch("reply").await.unwrap();
	let routes = DirectRoutes::new();
	let observer = routes.receiver();
	assert_eq!(
		observer.adopt(context, a.clone(), target_a.clone()).unwrap(),
		Adoption::Installed
	);
	assert_eq!(
		observer.adopt(context, a.clone(), target_a.clone()).unwrap(),
		Adoption::Repeated
	);
	assert_eq!(
		observer.adopt(context, b.clone(), target_b.clone()).unwrap(),
		Adoption::KeptLive
	);
	routes.say(context, "first").await.unwrap();
	assert_eq!(called.get(), 1);
	a.session().close(PendingWork::Cancel).await.unwrap();
	assert!(!routes.live(context));
	assert_eq!(
		observer.adopt(context, b.clone(), target_b.clone()).unwrap(),
		Adoption::Installed
	);
	routes.say(context, "replacement").await.unwrap();
	assert_eq!(called.get(), 2);
	drop(routes.clone());
	assert!(
		routes.live(context),
		"dropping a route clone must not close the shared owner"
	);
	drop(routes);
	assert!(observer.adopt(context, b.clone(), target_b.clone()).is_err());
	b.session().send(&target_b, "dm", &["sibling".into()]).await.unwrap();
	assert_eq!(called.get(), 3, "route drop preserves the shared connection");
	b.session().close(PendingWork::Cancel).await.unwrap();
	near_a.close(PendingWork::Cancel).await.unwrap();
	near_b.close(PendingWork::Cancel).await.unwrap();
	serve_a.await.unwrap().unwrap();
	serve_b.await.unwrap().unwrap();
	server.host().unpublish_giftable("reply").unwrap();
	server.close().await.unwrap();
	server.host().close(PendingWork::Cancel).await.unwrap();
	first.close(PendingWork::Cancel).await.unwrap();
	second.close(PendingWork::Cancel).await.unwrap();
}
pub(super) async fn close_pending(
	routes: &DirectRoutes,
	context: &AcceptedDirect,
	offer: &peers::Offer,
	peer: &mut Reciprocal,
) {
	let mut pending = Box::pin(routes.say(context, "pending"));
	let mut answer = tokio::select! {
		answer = peer.answers.recv() => answer.unwrap(),
		_ = &mut pending => panic!("pending route answered early"),
	};
	assert_eq!(peer.messages.recv().await.unwrap(), "pending");
	routes.close();
	assert!(!routes.live(context));
	assert!(routes.say(context, "after close").await.is_err());
	answer.fulfill(&Argument::Void).unwrap();
	assert!(
		pending.await.is_err(),
		"late acknowledgement must not restore the route"
	);
	// Closing the route owner cannot close the connection or sibling actors.
	assert!(offer.session.is_open());
	offer
		.session
		.send(&peer.line, "edit", &["still available".into()])
		.await
		.unwrap();
	assert_eq!(peer.edits.get(), 1);
}

pub(super) async fn independent(
	routes: &DirectRoutes,
	first: &AcceptedDirect,
	second: &AcceptedDirect,
	peer: &mut Reciprocal,
	sibling: &mut Reciprocal,
) {
	let mut pending = Box::pin(routes.say(first, "pending"));
	let mut answer = tokio::select! {
		answer = peer.answers.recv() => answer.unwrap(),
		_ = &mut pending => panic!("pending route answered early"),
	};
	assert_eq!(peer.messages.recv().await.unwrap(), "pending");
	routes.say(second, "while waiting").await.unwrap();
	assert_eq!(sibling.messages.recv().await.unwrap(), "while waiting");
	drop(pending);
	answer.fulfill(&Argument::Void).unwrap();
	routes.say(first, "after cancellation").await.unwrap();
	assert_eq!(peer.messages.recv().await.unwrap(), "after cancellation");
}
