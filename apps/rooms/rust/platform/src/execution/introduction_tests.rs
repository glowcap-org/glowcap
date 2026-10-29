//! Introduction retry policy and the direct exporter route over real CapTP.
use super::HostPlatform;
use glowcap::{Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig, Session, tcp};
use rooms_application::directory::{introduction as policy, registration::Id};
use rooms_application::{archive::ShareKind, direct::Notice};
use rooms_glowcap::client::{
	Client, Error, Tasks,
	direct::{self, Direct},
	directory::Directory,
};
use std::{
	cell::{Cell, RefCell},
	future::{Future, poll_fn},
	rc::Rc,
	task::Poll,
	time::Duration,
};
const ID: &str = "11111111-1111-4111-8111-111111111111";
#[derive(Clone, Default)]
struct Platform {
	expire_wait: Rc<Cell<bool>>,
}
impl rooms_glowcap::client::Deadline for Platform {
	fn monotonic_millis(&self) -> u64 {
		0
	}
	async fn within<T>(&self, milliseconds: u64, work: impl Future<Output = T>) -> Option<T> {
		if milliseconds == policy::WAIT_MS && self.expire_wait.replace(false) {
			return None;
		}
		HostPlatform.within(milliseconds, work).await
	}
}
impl Tasks for Platform {
	type Task = super::HostTask;
	fn spawn(&self, work: impl Future<Output = ()> + 'static) -> Self::Task {
		HostPlatform.spawn(work)
	}
}
fn serve(session: Rc<Session>) -> tokio::task::JoinHandle<glowcap::Result<()>> {
	tokio::task::spawn_local(async move { session.serve().await })
}
async fn runtime() -> Runtime {
	Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap()
}
fn notice(id: &str) -> [Argument; 4] {
	["introducible".into(), "bob".into(), id.into(), "opening".into()]
}
#[tokio::test]
async fn introduction_waits_match_registration_and_remain_bounded() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(10), waiting())
				.await
				.expect("introduction deadline");
		})
		.await;
}
async fn waiting() {
	let server = tcp::listen("127.0.0.1", 0, Default::default()).await.unwrap();
	let runtime = runtime().await;
	let locator = server.locator().unwrap();
	let (client, peer) = tokio::join!(runtime.connect(&locator, ConnectOptions::default()), server.accept());
	let peer = Rc::new(peer.unwrap());
	let serving = serve(peer.clone());
	let platform = Platform::default();
	let client = Client::new(client.unwrap(), platform.clone());
	let name = peer.spawn_owned(|_, _| Ok(Argument::Void)).unwrap();
	let dm = peer
		.spawn_owned(|verb, _| {
			let verb = verb.ok_or("fixture requires a method")?;
			assert_eq!(verb, "hello");
			Ok("bob".into())
		})
		.unwrap();
	let answer = Rc::new(RefCell::new(Argument::Reference(dm.clone())));
	let callback = Rc::new(RefCell::new(None::<glowcap::Ref>));
	let refusals = Rc::new(Cell::new(0usize));
	let early = Rc::new(Cell::new(false));
	let hard = Rc::new(Cell::new(false));
	let queries = Rc::new(Cell::new(0));
	let (tx, mut arrivals) = tokio::sync::mpsc::channel(512);
	let (service, inbox, named, reply, refuse, notify, fail, queried) = (
		peer.clone(),
		callback.clone(),
		name.clone(),
		answer.clone(),
		refusals.clone(),
		early.clone(),
		hard.clone(),
		queries.clone(),
	);
	let root = peer
		.publish("directory", move |verb, args| {
			match verb.ok_or("fixture requires a method")? {
				"register" => {
					let Argument::Reference(observer) = &args[2] else {
						panic!("registration inbox")
					};
					*inbox.borrow_mut() = Some(observer.clone());
					service
						.tell(observer, "notify", &["registered".into(), "alice".into(), ID.into()])
						.unwrap();
					Ok(Argument::List(vec![args[0].clone(), ID.into(), named.clone().into()]))
				}
				"memberRegistration" => {
					assert_eq!(args[0].as_str(), Some("bob"));
					queried.set(queried.get() + 1);
					Ok(ID.into())
				}
				"introduce" => {
					assert_eq!(args.len(), 3);
					assert_eq!(args[0].as_str(), Some("bob"));
					assert_eq!(args[1].as_str(), Some(ID));
					tx.try_send(()).unwrap();
					if notify.replace(false) {
						service
							.tell(inbox.borrow().as_ref().unwrap(), "notify", &notice(ID))
							.unwrap();
					}
					if fail.get() {
						return Err("peer-offline: gone".into());
					}
					if refuse.get() > 0 {
						refuse.set(refuse.get() - 1);
						return Err("introduction-pending: not offered".into());
					}
					Ok(reply.borrow().clone())
				}
				_ => Err("unknown directory verb".into()),
			}
		})
		.unwrap();
	let directory = Directory::fetch(client.clone()).await.unwrap();
	let id = Id::parse(ID).unwrap();
	let mut registration = directory.registration();
	registration.register("alice", "ocapn://alice.id", None).await.unwrap();
	let target = callback.borrow().clone().unwrap();
	let plain = directory.introduce_opening("bob", None, "opening").await.unwrap();
	assert_eq!(plain.registration, id);
	assert_eq!(queries.get(), 1);
	assert_eq!(
		plain.session().send(&plain.inbox, "hello", &[]).await.unwrap().as_str(),
		Some("bob")
	);
	arrivals.recv().await.unwrap();
	early.set(true);
	refusals.set(1);
	let introduced = directory.introduce_opening("bob", Some(&id), "opening").await.unwrap();
	arrivals.recv().await.unwrap();
	arrivals.recv().await.unwrap();
	assert_eq!(queries.get(), 1);
	assert_eq!(introduced.registration, id);
	hard.set(true);
	assert!(matches!(
		directory.introduce_opening("bob", Some(&id), "opening").await,
		Err(Error::Binding(_))
	));
	arrivals.recv().await.unwrap();
	hard.set(false);
	*answer.borrow_mut() = Argument::List(vec![dm.clone().into()]);
	assert!(matches!(
		directory.introduce_opening("bob", Some(&id), "opening").await,
		Err(Error::Introduction(policy::Error::Capability))
	));
	arrivals.recv().await.unwrap();
	*answer.borrow_mut() = dm.clone().into();

	// An unrelated registration cannot wake this caller. Cancellation removes
	// its wait; a later correct signal remains available to the next caller.
	refusals.set(1);
	let mut pending = Box::pin(directory.introduce_opening("bob", Some(&id), "opening"));
	tokio::select! { r=arrivals.recv()=>r.unwrap(),_=&mut pending=>panic!("early introduction") };
	peer.send(&target, "notify", &notice("22222222-2222-4222-8222-222222222222"))
		.await
		.unwrap();
	tokio::select! { biased; _=&mut pending=>panic!("wrong registration woke the caller"),_=tokio::task::yield_now()=>{} }
	drop(pending);
	peer.send(&target, "notify", &notice(ID)).await.unwrap();
	refusals.set(1);
	directory.introduce_opening("bob", Some(&id), "opening").await.unwrap();
	arrivals.recv().await.unwrap();
	arrivals.recv().await.unwrap();

	platform.expire_wait.set(true);
	refusals.set(1);
	assert!(matches!(
		directory.introduce_opening("bob", Some(&id), "opening").await,
		Err(Error::Introduction(policy::Error::Pending))
	));
	arrivals.recv().await.unwrap();
	refusals.set(policy::MAX_OUTSTANDING);
	let mut work: Vec<_> = (0..policy::MAX_OUTSTANDING)
		.map(|_| Box::pin(directory.introduce_opening("bob", Some(&id), "opening")))
		.collect();
	poll_fn(|cx| {
		for future in &mut work {
			assert!(future.as_mut().poll(cx).is_pending());
		}
		Poll::Ready(())
	})
	.await;
	assert!(matches!(
		directory.introduce_opening("bob", Some(&id), "opening").await,
		Err(Error::Introduction(policy::Error::Full))
	));
	for _ in 0..policy::MAX_OUTSTANDING {
		arrivals.recv().await.unwrap();
	}
	drop(work);
	refusals.set(0);
	directory.introduce_opening("bob", Some(&id), "opening").await.unwrap();
	arrivals.recv().await.unwrap();
	refusals.set(1);
	let mut waiting = Box::pin(directory.introduce_opening("bob", Some(&id), "opening"));
	tokio::select! { r=arrivals.recv()=>r.unwrap(),_=&mut waiting=>panic!("early introduction") };
	// The marker confirms the refusal crossed the wire before closing the
	// client; the introduction itself is still waiting for its notification.
	directory.member_registration("bob").await.unwrap();
	client.session().close(PendingWork::Cancel).await.unwrap();
	assert!(matches!(waiting.await, Err(Error::Introduction(policy::Error::Ended))));
	drop((
		plain,
		introduced,
		registration,
		directory,
		client,
		target,
		callback,
		dm,
		name,
		answer,
	));
	peer.release(root).unwrap();
	peer.close(PendingWork::Cancel).await.unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
	server.close().await.unwrap();
	server.host().close(PendingWork::Cancel).await.unwrap();
	serving.await.unwrap().unwrap();
}

#[tokio::test]
async fn introductions_keep_the_actual_exporter_and_reciprocal_inbox_route() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(15), handoff())
				.await
				.expect("three-party introduction deadline");
		})
		.await;
}
async fn handoff() {
	let exporter = Rc::new(tcp::listen("127.0.0.1", 0, Default::default()).await.unwrap());
	let reciprocal = Rc::new(RefCell::new(None::<(glowcap::Ref, Session)>));
	let received = reciprocal.clone();
	let messages = Rc::new(RefCell::new(Vec::new()));
	let received_messages = messages.clone();
	exporter
		.host()
		.publish("dm", move || {
			let received = received.clone();
			let messages = received_messages.clone();
			Box::new(direct::receiver(move |notice, session| {
				match notice {
					Notice::Ready(reply) => {
						*received.borrow_mut() = Some((reply, session));
					}
					Notice::Message {
						text,
						reply,
						attachments,
						previews,
					} => {
						assert!(previews.is_empty());
						assert!(attachments.is_empty());
						messages.borrow_mut().push(text.to_owned());
						if let Some(reply) = reply {
							*received.borrow_mut() = Some((reply, session));
						}
					}
					_ => return Err("unsupported sibling verb".into()),
				}
				Ok(Argument::Void)
			}))
		})
		.unwrap();
	let exported = Rc::new(RefCell::new(Vec::<Rc<Session>>::new()));
	let (accepting, connections) = (exporter.clone(), exported.clone());
	let accept_task = tokio::task::spawn_local(async move {
		let mut serving = Vec::new();
		for _ in 0..2 {
			let peer = Rc::new(accepting.accept().await.unwrap());
			connections.borrow_mut().push(peer.clone());
			serving.push(serve(peer));
		}
		for task in serving {
			task.await.unwrap().unwrap();
		}
	});
	let gifter = tcp::listen("127.0.0.1", 0, Default::default()).await.unwrap();
	let gifter_runtime =
		Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]).adopt_host(&gifter.host()))
			.await
			.unwrap();
	let to_exporter = gifter_runtime
		.connect(&exporter.locator().unwrap(), ConnectOptions::default())
		.await
		.unwrap();
	to_exporter
		.set_exporter_locator(Some(&exporter.locator().unwrap()))
		.unwrap();
	let dm = to_exporter.fetch("dm").await.unwrap();
	let handed = dm.clone();
	gifter
		.host()
		.publish("directory", move || {
			let handed = handed.clone();
			Box::new(move |verb, args| {
				let verb = verb.ok_or("fixture requires a method")?;
				assert_eq!(verb, "introduce");
				assert_eq!(args[1].as_str(), Some(ID));
				Ok(handed.clone().into())
			})
		})
		.unwrap();
	let recipient = runtime().await;
	let locator = gifter.locator().unwrap();
	let (connected, accepted) = tokio::join!(recipient.connect(&locator, ConnectOptions::default()), gifter.accept());
	let accepted = Rc::new(accepted.unwrap());
	let serving = serve(accepted.clone());
	let client = Client::new(connected.unwrap(), HostPlatform);
	let directory = Directory::fetch(client.clone()).await.unwrap();
	let id = Id::parse(ID).unwrap();
	let mut first = directory.direct("bob", Some(&id)).await.unwrap();
	assert_eq!(first.registration(), &id);
	assert!(first.say("first").await.unwrap().is_none());
	assert!(matches!(
		first.establish_reply_route().await,
		Err(Error::Direct(rooms_application::direct::Error::NoReply))
	));
	let replies = Rc::new(RefCell::new(Vec::new()));
	let received_replies = replies.clone();
	let mut second = directory
		.direct("bob", Some(&id))
		.await
		.unwrap()
		.with_receiver(move |notice, session| {
			let Notice::Message { text, .. } = notice else {
				return Err("messages only".into());
			};
			received_replies.borrow_mut().push(text.to_owned());
			// The delegated line survives the direct conversation's local close.
			let line = session
				.spawn_owned(|verb, args| {
					let verb = verb.ok_or("fixture requires a method")?;
					assert_eq!(verb, "edit");
					assert_eq!(args[0].as_str(), Some("after direct close"));
					Ok(Argument::Void)
				})
				.map_err(|e| e.to_string())?;
			Ok(line.into())
		})
		.unwrap();
	first.close();
	assert!(first.say("closed").await.is_err());
	// Closing either a sibling line or the directory cannot close the exporter.
	client.session().close(PendingWork::Cancel).await.unwrap();
	second.establish_reply_route().await.unwrap();
	assert!(second.say("second").await.unwrap().is_none());
	assert!(
		second
			.offer_room("label", "link")
			.await
			.unwrap_err()
			.to_string()
			.contains("unsupported sibling verb")
	);
	assert!(
		second
			.offer_archive("directory", ShareKind::Room, Some("room"), "link")
			.await
			.is_err()
	);
	assert_eq!(&*messages.borrow(), &["first", "second"]);
	assert_eq!(exported.borrow().len(), 2);
	let (reply_to, exporter_peer) = reciprocal.borrow_mut().take().unwrap();
	let mut reverse = Direct::adopt(Client::new(exporter_peer, HostPlatform), reply_to, id);
	let posted = reverse.say("reciprocal").await.unwrap().unwrap();
	assert_eq!(&*replies.borrow(), &["reciprocal"]);
	reverse.close();
	second.close();
	posted.edit("after direct close").await.unwrap();
	drop((first, second, reverse, posted, directory, client, reciprocal, dm));
	recipient.close(PendingWork::Cancel).await.unwrap();
	to_exporter.close(PendingWork::Cancel).await.unwrap();
	accepted.close(PendingWork::Cancel).await.unwrap();
	gifter.close().await.unwrap();
	gifter_runtime.close(PendingWork::Cancel).await.unwrap();
	exporter.close().await.unwrap();
	exporter.host().close(PendingWork::Cancel).await.unwrap();
	serving.await.unwrap().unwrap();
	accept_task.await.unwrap();
}
