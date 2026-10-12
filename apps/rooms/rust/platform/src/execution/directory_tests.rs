//! Directory clients consume real capabilities. Fixture actors control reply
//! ordering and shape without implementing production directory persistence.
use super::HostPlatform;
use glowcap::{Argument, ConnectOptions, Host, ListenerIdentity, PendingWork, Runtime, RuntimeConfig, tcp};
use rooms_application::{
	directory::{self, creation::RecoveryKey},
	room::policy::RoomPolicy,
};
use rooms_glowcap::client::{Client, Error, directory::Directory};
use serde_json::{Value, json};
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
	time::Duration,
};

fn argument(value: &Value) -> Argument {
	match value {
		Value::Null => Argument::Void,
		Value::Bool(on) => (*on).into(),
		Value::String(s) => s.as_str().into(),
		Value::Array(values) => Argument::List(values.iter().map(argument).collect()),
		Value::Number(n) => Argument::Float(n.as_f64().unwrap()),
		_ if value["integer"].is_string() => Argument::Integer(value["integer"].as_str().unwrap().parse().unwrap()),
		_ => Argument::List(vec![]),
	}
}
#[tokio::test]
async fn directory_bootstrap_and_watch_custody_follow_the_shared_connection() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(10), scenario())
				.await
				.expect("directory scenario deadline");
		})
		.await;
}
async fn scenario() {
	let fixture: Value = serde_json::from_str(include_str!("../../../proofs/fixtures/directory-client.json")).unwrap();
	let host = Host::from_seed([87; 32]).unwrap();
	let server = tcp::listen(
		"127.0.0.1",
		0,
		tcp::ListenOptions {
			identity: ListenerIdentity::Host(host.clone()),
			..Default::default()
		},
	)
	.await
	.unwrap();
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let locator = server.locator().unwrap();
	let (connected, accepted) = tokio::join!(runtime.connect(&locator, ConnectOptions::default()), server.accept());
	let accepted = Rc::new(accepted.unwrap());
	let service = accepted.clone();
	let serving = tokio::task::spawn_local(async move { service.serve().await });
	let client = Client::new(connected.unwrap(), HostPlatform);
	let room = accepted
		.spawn_owned(|verb, _| {
			assert_eq!(verb, "called");
			Ok("garden".into())
		})
		.unwrap();
	let room_link = fixture["roomLink"].as_str().unwrap().to_owned();
	let manager_link = fixture["managerLink"].as_str().unwrap().to_owned();
	let authority_reply = Rc::new(RefCell::new(Ok(Argument::List(vec![
		room_link.clone().into(),
		manager_link.clone().into(),
	]))));
	let calls = Rc::new(RefCell::new(Vec::<Value>::new()));
	let delayed = Rc::new(Cell::new(false));
	let (tx, mut resolvers) = tokio::sync::mpsc::channel(1);
	let (answer, recorded, delay, actor_host) = (authority_reply.clone(), calls.clone(), delayed.clone(), host.clone());
	let bootstrap = accepted
		.spawn_owned(move |verb, args| {
			assert_eq!(verb, "roomAuthorities");
			assert!(args.is_empty());
			recorded
				.borrow_mut()
				.push(json!({"target":"bootstrap","verb":verb,"args":[]}));
			if delay.get() {
				tx.try_send(actor_host.defer_turn().unwrap()).unwrap();
				Ok(Argument::Void)
			} else {
				answer.borrow().clone()
			}
		})
		.unwrap();
	let list_reply = Rc::new(RefCell::new(argument(&fixture["lists"][3]["input"])));
	let watch_reply = Rc::new(RefCell::new(argument(&fixture["snapshots"][0]["input"])));
	let watch_event = Rc::new(RefCell::new(Some(argument(&fixture["events"][0]["input"]))));
	let watcher = Rc::new(RefCell::new(None::<glowcap::Ref>));
	let malformed = Rc::new(Cell::new(false));
	let (service, member, boot, lists, snapshot, event, observer, bad, recorded) = (
		accepted.clone(),
		room.clone(),
		bootstrap.clone(),
		list_reply.clone(),
		watch_reply.clone(),
		watch_event.clone(),
		watcher.clone(),
		malformed.clone(),
		calls.clone(),
	);
	let root = accepted
		.publish("directory", move |verb, args| match verb {
			"openManaged" => {
				recorded.borrow_mut().push(
					json!({"target":"directory","verb":verb,"args":args.iter().map(|v|v.as_str().unwrap()).collect::<Vec<_>>()}),
				);
				Ok(Argument::List(if bad.get() {
					vec![member.clone().into()]
				} else {
					vec![member.clone().into(), boot.clone().into()]
				}))
			}
			"open" => {
				if args.len() == 3 {
					assert_eq!(args[1].as_bool(), Some(true));
					assert!(args[2].as_str().unwrap().starts_with('~'));
				} else {
					assert_eq!(args.len(), 1);
				}
				Ok(if bad.get() {
					Argument::Void
				} else {
					member.clone().into()
				})
			}
			"enter" | "enterPublication" => {
				assert_eq!(args.len(), 1);
				Ok(member.clone().into())
			}
			"link" | "openPrivateLink" => {
				assert_eq!(args.len(), 1);
				Ok(room_link.clone().into())
			}
			"advertisedLocation" => {
				assert!(args.is_empty());
				Ok("directory.id".into())
			}
			"listPublications" => {
				assert!(args.is_empty());
				Ok(lists.borrow().clone())
			}
			"watchPublications" => {
				let [Argument::Reference(inbox)] = args else {
					panic!("watch expects one observer")
				};
				*observer.borrow_mut() = Some(inbox.clone());
				if let Some(Argument::List(args)) = event.borrow().as_ref() {
					service.tell(inbox, "notify", args).unwrap();
				}
				Ok(snapshot.borrow().clone())
			}
			_ => Err("unknown directory verb".into()),
		})
		.unwrap();
	let directory = Directory::fetch(client.clone()).await.unwrap();
	let other_root = accepted
		.publish("other-directory", |verb, args| {
			assert_eq!(verb, "watchPublications");
			assert!(matches!(args, [Argument::Reference(_)]));
			Ok(Argument::List(vec![
				Argument::List(vec![]),
				Argument::List(vec![]),
				0.into(),
			]))
		})
		.unwrap();
	let other_directory = Directory::new(client.clone(), client.session().fetch("other-directory").await.unwrap());
	let key = RecoveryKey::parse(fixture["keys"][0]["input"].as_str().unwrap().into()).unwrap();
	let managed = directory
		.open_managed("garden", RoomPolicy::Private, &key)
		.await
		.unwrap();
	assert_eq!(json!(*calls.borrow()), fixture["calls"]);
	assert_eq!(managed.room_link, fixture["roomLink"].as_str().unwrap());
	assert_eq!(managed.manager_link, fixture["managerLink"].as_str().unwrap());
	assert_eq!(client.room_called(&managed.room).await.unwrap(), "garden");
	assert_eq!(
		client.room_called(&directory.open("new").await.unwrap()).await.unwrap(),
		"garden"
	);
	directory.enter("garden").await.unwrap();
	directory.enter_publication("foreign-id").await.unwrap();
	directory.open_private("private", &key).await.unwrap();
	assert_eq!(directory.private_link(&key).await.unwrap(), managed.room_link);
	assert_eq!(directory.link("garden").await.unwrap(), managed.room_link);
	assert_eq!(directory.advertised_location().await.unwrap(), "directory.id");
	assert_eq!(
		serde_json::to_value(directory.list().await.unwrap()).unwrap(),
		fixture["lists"][3]["result"]
	);
	*list_reply.borrow_mut() = Argument::List(vec![room.clone().into()]);
	assert!(matches!(
		directory.list().await,
		Err(Error::Directory(directory::Error::Row))
	));
	malformed.set(true);
	assert!(matches!(
		directory.open("bad").await,
		Err(Error::Directory(directory::Error::Capability))
	));
	assert!(matches!(
		directory.open_managed("bad", RoomPolicy::Open, &key).await,
		Err(Error::Directory(directory::Error::Bootstrap))
	));
	malformed.set(false);
	let original = authority_reply.borrow().clone();
	for bad in [
		Argument::List(vec!["bad".into(), "bad".into()]),
		Argument::List(vec!["only one".into()]),
		Argument::Reference(room.clone()),
	] {
		*authority_reply.borrow_mut() = Ok(bad);
		assert!(
			directory
				.open_managed("garden", RoomPolicy::Private, &key)
				.await
				.is_err()
		);
	}
	*authority_reply.borrow_mut() = original;
	delayed.set(true);
	let mut pending = Box::pin(directory.open_managed("garden", RoomPolicy::Private, &key));
	let mut resolver = tokio::select! {r=resolvers.recv()=>r.unwrap(),_=&mut pending=>panic!("early bootstrap answer")};
	drop(pending);
	delayed.set(false);
	directory
		.open_managed("garden", RoomPolicy::Private, &key)
		.await
		.unwrap();
	resolver.fulfill(authority_reply.borrow().as_ref().unwrap()).unwrap();
	let mut first = directory.watch().await.unwrap();
	assert_eq!(
		serde_json::to_value(first.snapshot()).unwrap(),
		fixture["snapshots"][0]["result"]
	);
	assert_eq!(
		serde_json::to_value(first.next().await.unwrap()).unwrap(),
		fixture["events"][0]["result"]
	);
	let mut other_watch = other_directory.watch().await.unwrap();
	let first_target = watcher.borrow().clone().unwrap();
	accepted
		.send(&first_target, "notify", &["truncated".into(), 9.into()])
		.await
		.unwrap();
	assert!(matches!(first.next().await, Ok(Some(directory::Event::Truncated(9)))));
	// Another handle on this same connection replaces the old watcher too.
	let sibling = Directory::new(client.clone(), directory.reference().clone());
	let mut second = sibling.watch().await.unwrap();
	assert!(first.next().await.unwrap().is_none());
	second.next().await.unwrap().unwrap();
	*watch_reply.borrow_mut() = Argument::Void;
	assert!(sibling.watch().await.is_err());
	assert!(second.next().await.unwrap().is_none());
	let abandoned = watcher.borrow().clone().unwrap();
	assert!(
		accepted
			.send(&abandoned, "notify", &["truncated".into(), 1.into()])
			.await
			.is_err()
	);
	*watch_reply.borrow_mut() = argument(&fixture["snapshots"][0]["input"]);
	*watch_event.borrow_mut() = None;
	let mut slow = directory.watch().await.unwrap();
	let target = watcher.borrow().clone().unwrap();
	// Event records are individually bounded by their shared types; retaining
	// more than MAX_ROWS would conceal a gap in this complete directory view.
	for i in 0..directory::MAX_ROWS {
		accepted
			.send(&target, "notify", &["truncated".into(), Argument::Integer(i as i64)])
			.await
			.unwrap();
	}
	assert!(
		accepted
			.send(&target, "notify", &["truncated".into(), 1.into()])
			.await
			.is_err()
	);
	assert!(matches!(slow.next().await, Err(directory::Error::Overflow)));
	let mut live = directory.watch().await.unwrap();
	client.session().close(PendingWork::Cancel).await.unwrap();
	assert!(live.next().await.unwrap().is_none());
	assert!(other_watch.next().await.unwrap().is_none());
	drop((other_watch, other_directory, first_target));
	accepted.release(other_root).unwrap();
	drop((first, second, slow, live, sibling, directory, managed, client));
	accepted.release(root).unwrap();
	drop((watcher, target, abandoned, room, bootstrap));
	accepted.close(PendingWork::Cancel).await.unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
	server.close().await.unwrap();
	host.close(PendingWork::Cancel).await.unwrap();
	serving.await.unwrap().unwrap();
}
