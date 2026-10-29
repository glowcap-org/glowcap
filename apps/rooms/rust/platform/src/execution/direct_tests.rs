//! Direct receiver effects and exact client calls over actual TCP capabilities.
use super::HostPlatform;
use glowcap::{Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig, tcp};
use rooms_application::{archive::ShareKind, direct::Notice, directory::registration::Id};
use rooms_glowcap::client::{
	Client,
	direct::{self, Direct},
};
use std::{cell::RefCell, rc::Rc, time::Duration};

#[tokio::test]
async fn direct_sibling_calls_and_deferred_effects_observe_the_receiver() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(10), scenario()).await.unwrap();
		})
		.await;
}
async fn scenario() {
	let server = tcp::listen("127.0.0.1", 0, Default::default()).await.unwrap();
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let locator = server.locator().unwrap();
	let (caller, peer) = tokio::join!(runtime.connect(&locator, ConnectOptions::default()), server.accept());
	let peer = Rc::new(peer.unwrap());
	let service = peer.clone();
	let serving = tokio::task::spawn_local(async move { service.serve().await });
	let client = Client::new(caller.unwrap(), HostPlatform);
	let seen = Rc::new(RefCell::new(Vec::new()));
	let notices = seen.clone();
	let (tx, mut effects) = tokio::sync::mpsc::channel(1);
	let root = peer
		.publish(
			"direct",
			direct::receiver(move |notice, session| {
				match notice {
					Notice::Message {
						text,
						reply,
						attachments,
						previews,
					} => {
						assert!(previews.is_empty());
						assert!(reply.is_none());
						if text == "defer" {
							tx.try_send(session.host().defer_turn().unwrap()).unwrap();
						} else {
							assert_eq!(text, "file");
							assert_eq!(attachments.len(), 1);
							assert_eq!(attachments[0].description.name(), "note");
						}
						notices.borrow_mut().push("message");
					}
					Notice::Typing(on) => {
						assert!(on);
						notices.borrow_mut().push("typing");
					}
					Notice::HandRoom { label, room } => {
						assert_eq!(label, "Room one");
						session.tell(&room, "handed", &[]).unwrap();
						notices.borrow_mut().push("handRoom");
					}
					Notice::OfferRoom { label, link } => {
						assert_eq!((label, link), ("Room two", "room-link"));
						notices.borrow_mut().push("offerRoom");
					}
					Notice::HandArchive {
						directory,
						kind,
						conversation,
						archive,
					} => {
						assert_eq!(
							(directory, kind, conversation),
							("Directory one", ShareKind::Standing, None)
						);
						session.tell(&archive, "handed", &[]).unwrap();
						notices.borrow_mut().push("handArchive");
					}
					Notice::OfferArchive {
						directory,
						kind,
						conversation,
						link,
					} => {
						assert_eq!(
							(directory, kind, conversation, link),
							("Directory two", ShareKind::Direct, Some("peer"), "archive-link")
						);
						notices.borrow_mut().push("offerArchive");
					}
					Notice::Ready(_) => return Err("no ready receiver".into()),
				}
				Ok(Argument::Void)
			}),
		)
		.unwrap();
	let target = client.session().fetch("direct").await.unwrap();
	let direct = Direct::adopt(
		client.clone(),
		target.clone(),
		Id::parse("11111111-1111-4111-8111-111111111111").unwrap(),
	);
	let (tx, mut handed) = tokio::sync::mpsc::channel(2);
	let authority = client
		.session()
		.spawn_owned(move |verb, args| {
			let verb = verb.ok_or("fixture requires a method")?;
			assert_eq!(verb, "handed");
			assert!(args.is_empty());
			tx.try_send(()).unwrap();
			Ok(Argument::Void)
		})
		.unwrap();
	direct.typing(true).unwrap();
	direct.hand_room("Room one", &authority).await.unwrap();
	direct.offer_room("Room two", "room-link").await.unwrap();
	direct
		.hand_archive("Directory one", ShareKind::Standing, None, &authority)
		.await
		.unwrap();
	direct
		.offer_archive("Directory two", ShareKind::Direct, Some("peer"), "archive-link")
		.await
		.unwrap();
	handed.recv().await.unwrap();
	handed.recv().await.unwrap();
	// The receiver's returned placeholder cannot acknowledge a deferred effect.
	let mut pending = Box::pin(direct.say("defer"));
	let mut effect =
		tokio::select! {r=effects.recv()=>r.unwrap(),_=&mut pending=>panic!("effect acknowledged before commit")};
	tokio::select! {biased; _=&mut pending=>panic!("early acknowledgement"),_=tokio::task::yield_now()=>{}}
	effect.break_with("storage refused").unwrap();
	assert!(pending.await.err().unwrap().to_string().contains("storage refused"));
	let args = [
		"file".into(),
		"file".into(),
		"note".into(),
		"text/plain".into(),
		Argument::Integer(1),
		authority.clone().into(),
		Argument::Integer(0),
		Argument::Integer(0),
		Argument::List(vec![authority.clone().into()]),
	];
	client.session().send(&target, "dm", &args).await.unwrap();
	assert!(
		client
			.session()
			.send(&target, "directReady", &[authority.clone().into()])
			.await
			.is_err()
	);
	assert!(
		client
			.session()
			.send(&target, "typing", &[true.into(), authority.clone().into()])
			.await
			.is_err()
	);
	assert!(
		client
			.session()
			.send(&target, "unknown", &[authority.clone().into()])
			.await
			.is_err()
	);
	assert_eq!(
		&*seen.borrow(),
		&[
			"typing",
			"handRoom",
			"offerRoom",
			"handArchive",
			"offerArchive",
			"message",
			"message"
		]
	);
	drop((direct, target, authority, args, client));
	peer.release(root).unwrap();
	peer.close(PendingWork::Cancel).await.unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
	server.close().await.unwrap();
	server.host().close(PendingWork::Cancel).await.unwrap();
	serving.await.unwrap().unwrap();
}
