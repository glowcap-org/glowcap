//! Registration ordering and custody over real host CapTP connections.
use super::HostPlatform;
use glowcap::{Argument, ConnectOptions, Host, ListenerIdentity, PendingWork, Runtime, RuntimeConfig, tcp};
use rooms_application::directory::registration::{self as policy, Id, Kind, NicknameAllocation};
use rooms_glowcap::client::{Client, Error, Tasks, directory::Directory};
use serde_json::{Value, json};
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
	time::Duration,
};

const ID: &str = "11111111-1111-4111-8111-111111111111";
#[derive(Clone, Default)]
struct Platform;
impl rooms_glowcap::client::Deadline for Platform {
	fn monotonic_millis(&self) -> u64 {
		0
	}
	async fn within<T>(&self, milliseconds: u64, work: impl core::future::Future<Output = T>) -> Option<T> {
		HostPlatform.within(milliseconds, work).await
	}
}
impl Tasks for Platform {
	type Task = super::HostTask;
	fn spawn(&self, work: impl core::future::Future<Output = ()> + 'static) -> Self::Task {
		HostPlatform.spawn(work)
	}
}
fn project(arg: &Argument) -> Value {
	match arg {
		Argument::Reference(_) => json!({"capability":true}),
		Argument::Bytes(bytes) => json!({"bytes":bytes}),
		Argument::String(s) => json!(s),
		_ => panic!("unexpected registration argument"),
	}
}
fn granted(nick: &str, name: &glowcap::Ref) -> Argument {
	Argument::List(vec![nick.into(), ID.into(), name.clone().into()])
}
fn ack() -> [Argument; 3] {
	["registered".into(), "alice".into(), ID.into()]
}
fn event() -> [Argument; 4] {
	["introducible".into(), "bob".into(), ID.into(), "opening".into()]
}
#[tokio::test]
async fn registration_binds_identity_to_custody_and_retains_cancelled_observation() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(10), scenario())
				.await
				.expect("registration scenario deadline");
		})
		.await;
}
async fn scenario() {
	let fixture: Value =
		serde_json::from_str(include_str!("../../../proofs/fixtures/registration-client.json")).unwrap();
	let host = Host::from_seed([89; 32]).unwrap();
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
	let platform = Platform;
	let client = Client::new(connected.unwrap(), platform.clone());
	let calls = Rc::new(RefCell::new(Vec::<Value>::new()));
	let voucher = Rc::new(RefCell::new(Argument::Bytes(vec![1, 2, 3])));
	let (recorded, answer) = (calls.clone(), voucher.clone());
	let first_name = accepted
		.spawn_owned(move |verb, args| {
			let verb = verb.ok_or("fixture requires a method")?;
			assert_eq!(verb, "voucher");
			recorded
				.borrow_mut()
				.push(json!({"target":"name","verb":verb,"args":args.iter().map(project).collect::<Vec<_>>()}));
			Ok(answer.borrow().clone())
		})
		.unwrap();
	let second_name = accepted
		.spawn_owned(|verb, _| {
			let verb = verb.ok_or("fixture requires a method")?;
			assert_eq!(verb, "voucher");
			Ok(Argument::Bytes(vec![9]))
		})
		.unwrap();
	let name_reply = Rc::new(RefCell::new(Ok(granted("alice", &first_name))));
	let pending_reply = Rc::new(RefCell::new(None::<(glowcap::Resolver, Result<Argument, String>)>));
	let notify = Rc::new(RefCell::new(None::<glowcap::Ref>));
	let held_reply = Rc::new(Cell::new(false));
	let (tx, mut arrived) = tokio::sync::mpsc::channel(16);
	let (service, observer, held, answer, recorded) = (
		accepted.clone(),
		notify.clone(),
		held_reply.clone(),
		name_reply.clone(),
		calls.clone(),
	);
	let pending = pending_reply.clone();
	let root = accepted
		.publish("directory", move |verb, args| {
			let verb = verb.ok_or("fixture requires a method")?;
			recorded
				.borrow_mut()
				.push(json!({"target":"directory","verb":verb,"args":args.iter().map(project).collect::<Vec<_>>()}));
			match verb {
				"register" => {
					let Argument::Reference(inbox) = &args[2] else {
						panic!("registration needs an inbox")
					};
					*observer.borrow_mut() = Some(inbox.clone());
					let reply = if held.get() {
						*pending.borrow_mut() = Some((service.host().defer_turn().unwrap(), answer.borrow().clone()));
						Ok(Argument::Void)
					} else {
						answer.borrow().clone()
					};
					tx.try_send(()).unwrap();
					reply
				}
				"memberRegistration" => Ok(ID.into()),
				"requestDirect" => Ok(Argument::Void),
				"offerInbox" => {
					assert!(matches!(args[3], Argument::Reference(_)));
					Ok(Argument::Void)
				}
				_ => Err("unknown directory verb".into()),
			}
		})
		.unwrap();
	let directory = Directory::fetch(client.clone()).await.unwrap();
	let mut registration = directory.registration();
	assert!(registration.name_voucher().await.unwrap().is_none());
	assert_eq!(
		registration
			.register("alice", "ocapn://alice.id", Some(vec![7, 8]))
			.await
			.unwrap()
			.as_str(),
		ID
	);
	arrived.recv().await.unwrap();
	let id = directory.member_registration("bob").await.unwrap();
	directory.request_direct("bob", &id).await.unwrap();
	let inbox = client.session().spawn_owned(|_, _| Ok(Argument::Void)).unwrap();
	directory.offer_inbox("bob", &id, "opening", &inbox).await.unwrap();
	assert_eq!(registration.name_voucher().await.unwrap(), Some(vec![1, 2, 3]));
	assert_eq!(json!(*calls.borrow()), fixture["calls"]);

	// A granted nickname is checked in the same reply as its exact capability.
	*name_reply.borrow_mut() = Ok(granted("alice-2", &first_name));
	assert!(matches!(
		registration.register("alice", "ocapn://alice.id", None).await,
		Err(Error::Registration(policy::Error::Grant))
	));
	arrived.recv().await.unwrap();
	assert_eq!(registration.name_voucher().await.unwrap(), Some(vec![1, 2, 3]));
	*name_reply.borrow_mut() = Ok(granted("guest-2", &first_name));
	let grant = registration
		.register_with_allocation("guest", NicknameAllocation::Automatic, "ocapn://alice.id", None)
		.await
		.unwrap();
	arrived.recv().await.unwrap();
	assert_eq!(grant.nick.text().as_str(), Some("guest-2"));
	let first_target = notify.borrow().clone().unwrap();
	accepted.send(&first_target, "notify", &event()).await.unwrap();
	let e = registration.next().await.unwrap().unwrap();
	assert_eq!(e.kind, Kind::Introducible);
	assert_eq!(e.peer.text().as_str(), Some("bob"));
	assert_eq!(e.registration.as_str(), ID);
	assert!(
		accepted
			.send(
				&first_target,
				"notify",
				&["introducible".into(), "bob".into(), "bad".into()]
			)
			.await
			.is_err()
	);

	// A dropped observer leaves one recoverable attempt, never a silent retry.
	held_reply.set(true);
	*name_reply.borrow_mut() = Ok(granted("alice", &second_name));
	let mut pending = Box::pin(registration.register("alice", "ocapn://alice.id", None));
	tokio::select! { r=arrived.recv()=>r.unwrap(), _=&mut pending=>panic!("registration finished without its reply") };
	drop(pending);
	assert!(matches!(
		registration.name_voucher().await,
		Err(Error::Registration(policy::Error::Busy))
	));
	assert!(matches!(
		registration.register("alice", "ocapn://alice.id", None).await,
		Err(Error::Registration(policy::Error::Busy))
	));
	let second_target = notify.borrow().clone().unwrap();
	let (mut answer, result) = pending_reply.borrow_mut().take().unwrap();
	answer.fulfill_value(&result.unwrap()).unwrap();
	assert_eq!(registration.finish_pending().await.unwrap().as_str(), ID);
	assert_eq!(registration.name_voucher().await.unwrap(), Some(vec![9]));
	assert!(accepted.send(&first_target, "notify", &event()).await.is_err());

	// A refused or malformed capability reply cannot replace the accepted name.
	held_reply.set(false);
	for reply in [Err("registration refused".into()), Ok(Argument::Void)] {
		*name_reply.borrow_mut() = reply;
		assert!(registration.register("alice", "ocapn://alice.id", None).await.is_err());
		arrived.recv().await.unwrap();
		assert_eq!(registration.name_voucher().await.unwrap(), Some(vec![9]));
		let rejected = notify.borrow().clone().unwrap();
		assert!(accepted.send(&rejected, "notify", &event()).await.is_err());
	}
	// Registration completes even when no discovery acknowledgement arrives.
	*name_reply.borrow_mut() = Ok(granted("alice", &first_name));
	registration.register("alice", "ocapn://alice.id", None).await.unwrap();
	arrived.recv().await.unwrap();
	assert_eq!(registration.name_voucher().await.unwrap(), Some(vec![1, 2, 3]));
	*voucher.borrow_mut() = Argument::Void;
	assert!(matches!(
		registration.name_voucher().await,
		Err(Error::Registration(policy::Error::Voucher))
	));
	*voucher.borrow_mut() = Argument::Bytes(vec![1, 2, 3]);
	let target = notify.borrow().clone().unwrap();
	for _ in 0..policy::MAX_EVENTS {
		accepted.send(&target, "notify", &event()).await.unwrap();
	}
	assert!(accepted.send(&target, "notify", &event()).await.is_err());
	assert!(matches!(
		registration.next().await,
		Err(Error::Registration(policy::Error::Overflow))
	));
	assert!(matches!(
		registration.next().await,
		Err(Error::Registration(policy::Error::Overflow))
	));

	held_reply.set(false);
	registration.register("alice", "ocapn://alice.id", None).await.unwrap();
	arrived.recv().await.unwrap();
	let retired = notify.borrow().clone().unwrap();
	let taken = registration.take_name().unwrap().unwrap();
	assert!(registration.name_voucher().await.unwrap().is_none());
	assert!(accepted.send(&retired, "notify", &event()).await.is_err());
	assert!(matches!(
		client.session().send(&taken, "voucher", &[]).await.unwrap(),
		Argument::Bytes(_)
	));
	registration.register("alice", "ocapn://alice.id", None).await.unwrap();
	arrived.recv().await.unwrap();
	// Dropping the owner cancels the attempt and retires its callback even
	// though the remote actor still holds the observer occurrence.
	held_reply.set(true);
	let mut abandoned_owner = directory.registration();
	let mut pending = Box::pin(abandoned_owner.register("alice", "ocapn://alice.id", None));
	tokio::select! { r=arrived.recv()=>r.unwrap(), _=&mut pending=>panic!("early registration reply") };
	drop(pending);
	let abandoned_target = notify.borrow().clone().unwrap();
	drop(abandoned_owner);
	assert!(accepted.send(&abandoned_target, "notify", &ack()).await.is_err());
	let mut closing_owner = directory.registration();
	let mut pending = Box::pin(closing_owner.register("alice", "ocapn://alice.id", None));
	tokio::select! { r=arrived.recv()=>r.unwrap(), _=&mut pending=>panic!("early acknowledgement") };
	drop(pending);
	// Session closure resolves the unobserved attempt from its actual state. If
	// its capability reply won first, that acceptance also retires the predecessor;
	// neither outcome may leave an inbox that appears live. Retire the local
	// publication before closing its consumer so cleanup queues no late release.
	accepted.release(root).unwrap();
	client.session().close(PendingWork::Cancel).await.unwrap();
	assert!(registration.next().await.unwrap().is_none());
	assert!(matches!(
		closing_owner.finish_pending().await,
		Err(Error::Registration(policy::Error::Ended))
	));
	drop((closing_owner, abandoned_target));
	// The closure is terminal even for a new observation.
	assert!(registration.next().await.unwrap().is_none());
	assert!(matches!(
		registration.register("alice", "ocapn://alice.id", None).await,
		Err(Error::Registration(policy::Error::Ended))
	));
	drop((
		registration,
		directory,
		client,
		inbox,
		taken,
		first_target,
		second_target,
		target,
		retired,
	));
	drop((notify, name_reply, first_name, second_name, pending_reply));
	// No late writes remain after callback retirement. The resident can finish
	// the peer's clean close without a transport failure.
	accepted.close(PendingWork::Cancel).await.unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
	server.close().await.unwrap();
	host.close(PendingWork::Cancel).await.unwrap();
	serving.await.unwrap().unwrap();
	assert_eq!(id, Id::parse(ID).unwrap());
}
