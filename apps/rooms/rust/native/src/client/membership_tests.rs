use super::Deadline;
use glowcap::{
	tcp, Argument, ConnectOptions, Host, ListenerIdentity, PendingWork, Ref, Resolver, Runtime, RuntimeConfig, Session,
};
use rooms_application::room::{inbox, membership, policy::MembershipKind};
use rooms_glowcap::client::{
	room::{Messages, Room, SubscribeOptions},
	Client, Error,
};
use std::{cell::RefCell, rc::Rc};
use tokio::sync::{mpsc, Notify};
struct Request {
	inbox: Ref,
}
async fn subscribe(
	client: &Client<Deadline>,
	server: &Session,
	requests: &mut mpsc::Receiver<Request>,
	name: &str,
) -> (Room<Deadline>, Messages, Ref) {
	let reference = client.session().fetch(name).await.unwrap();
	let (joined, inbox) = tokio::join!(
		Room::subscribe(client.clone(), reference, "alice", SubscribeOptions::default()),
		async {
			let request = requests.recv().await.unwrap();
			let arrival = ["room".into(), "".into(), "listed".into(), Argument::Boolean(false)];
			if name != "alpha" {
				server.send(&request.inbox, inbox::NOTIFY, &arrival).await.unwrap();
			}
			request.inbox
		}
	);
	let (room, messages) = joined.unwrap();
	(room, messages, inbox)
}
#[tokio::test]
async fn memberships_own_callbacks_arrival_and_goodbye_on_a_shared_connection() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(std::time::Duration::from_secs(10), membership_scenario())
				.await
				.expect("membership scenario deadline");
		})
		.await;
}
async fn membership_scenario() {
	let host = Host::from_seed([83; 32]).unwrap();
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
	let (client, accepted) = tokio::join!(runtime.connect(&locator, ConnectOptions::default()), server.accept());
	let accepted = Rc::new(accepted.unwrap().with_gc());
	let serving_session = accepted.clone();
	let serving = tokio::task::spawn_local(async move { serving_session.serve().await });
	let client = Client::new(client.unwrap(), Deadline);
	let (tx, mut requests) = mpsc::channel(8);
	let calls = Rc::new(RefCell::new(Vec::new()));
	let goodbye: Rc<RefCell<Option<Resolver>>> = Rc::new(RefCell::new(None));
	let goodbye_started = Rc::new(Notify::new());
	let mut roots = Vec::new();
	for name in ["alpha", "beta", "cancel", "broken", "ended"] {
		let (seen, goodbye, started, actor_host) =
			(calls.clone(), goodbye.clone(), goodbye_started.clone(), host.clone());
		let seat = accepted
			.spawn_owned(move |verb, args| {
				seen.borrow_mut().push((name, verb.to_owned()));
				match verb {
					membership::AWAY => {
						assert_eq!(args[0].as_str(), Some("back soon"));
						Ok(Argument::Void)
					}
					membership::TYPING => {
						assert_eq!(args[0].as_bool(), Some(true));
						Ok(Argument::Void)
					}
					membership::LEAVE if name == "cancel" => {
						*goodbye.borrow_mut() = Some(actor_host.defer_turn().unwrap());
						started.notify_one();
						Ok(Argument::Void)
					}
					membership::LEAVE => Err("goodbye refused".into()),
					_ => Err("unexpected membership verb".into()),
				}
			})
			.unwrap();
		let topic = if name == "alpha" {
			Some(
				accepted
					.spawn_owned(|verb, args| {
						assert_eq!(verb, membership::SET_TOPIC);
						assert_eq!(args[0].as_str(), Some("new topic"));
						Ok(Argument::Void)
					})
					.unwrap(),
			)
		} else {
			None
		};
		let (arriving_session, tx) = (accepted.clone(), tx.clone());
		roots.push(
			accepted
				.publish(name, move |verb, args| {
					assert_eq!(verb, membership::SUBSCRIBE);
					assert_eq!(args.len(), 2);
					assert_eq!(args[0].as_str(), Some("alice"));
					let Argument::Reference(inbox) = &args[1] else {
						panic!("subscription omitted its inbox")
					};
					let inbox = inbox.clone();
					let kind = if name == "beta" { "observer" } else { "participant" };
					if name == "alpha" {
						arriving_session
							.tell(
								&inbox,
								inbox::NOTIFY,
								&["room".into(), "".into(), "listed".into(), Argument::Boolean(false)],
							)
							.unwrap();
					} else if name == "ended" {
						arriving_session
							.tell(
								&inbox,
								inbox::NOTIFY,
								&["room".into(), "retired".into(), inbox::ENDED.into()],
							)
							.unwrap();
					}
					tx.try_send(Request { inbox }).unwrap();
					Ok(Argument::List(vec![
						seat.clone().into(),
						if name == "broken" {
							"invalid".into()
						} else {
							kind.into()
						},
						topic.clone().map(Argument::Reference).unwrap_or(Argument::Void),
					]))
				})
				.unwrap(),
		);
	}
	let (alpha, mut alpha_messages, alpha_inbox) = subscribe(&client, &accepted, &mut requests, "alpha").await;
	let (beta, mut beta_messages, beta_inbox) = subscribe(&client, &accepted, &mut requests, "beta").await;
	assert_eq!(alpha.kind().unwrap(), MembershipKind::Participant);
	assert_eq!(beta.kind().unwrap(), MembershipKind::Observer);
	assert_eq!(alpha.listed(), Some(true));
	alpha.away("back soon").await.unwrap();
	alpha.typing(true).unwrap();
	alpha.set_topic("new topic").await.unwrap();
	assert!(matches!(
		beta.set_topic("no authority").await,
		Err(Error::Membership(membership::Error::NoTopic))
	));
	accepted
		.send(
			&alpha_inbox,
			inbox::NOTIFY,
			&["alice".into(), "hello".into(), "line".into(), Argument::Integer(1)],
		)
		.await
		.unwrap();
	let line = alpha_messages.next().await.unwrap().unwrap();
	assert_eq!(line.text, "hello");
	assert_eq!(line.marker.unwrap().id.get(), 1);
	assert!(accepted.send(&alpha_inbox, "unknown", &[]).await.is_err());
	for name in ["broken", "ended"] {
		let reference = client.session().fetch(name).await.unwrap();
		let (joined, old_inbox) = tokio::join!(
			Room::subscribe(client.clone(), reference, "alice", Default::default()),
			async { requests.recv().await.unwrap().inbox }
		);
		assert!(joined.is_err());
		assert!(accepted
			.send(&old_inbox, inbox::NOTIFY, &["room".into(), "late".into()])
			.await
			.is_err());
	}
	// Cancellation while awaiting arrival releases the local inbox root.
	// The partner may still hold its exported callback, which now refuses.
	let reference = client.session().fetch("cancel").await.unwrap();
	let mut pending = Box::pin(Room::subscribe(client.clone(), reference, "alice", Default::default()));
	let request =
		tokio::select! { r=requests.recv()=>r.unwrap(), _=&mut pending=>panic!("subscription answered too early") };
	drop(pending);
	assert!(accepted
		.send(&request.inbox, inbox::NOTIFY, &["room".into(), "late".into()])
		.await
		.is_err());
	accepted
		.send(
			&beta_inbox,
			inbox::NOTIFY,
			&["room".into(), "removed".into(), inbox::ENDED.into()],
		)
		.await
		.unwrap();
	assert_eq!(beta.ended_reason().as_deref(), Some("removed"));
	assert!(beta_messages.next().await.unwrap().is_none());
	alpha.away("back soon").await.unwrap();
	let error = alpha.leave().await.unwrap_err().to_string();
	assert_eq!(alpha.leave().await.unwrap_err().to_string(), error);
	assert_eq!(
		calls
			.borrow()
			.iter()
			.filter(|(name, verb)| *name == "alpha" && verb == membership::LEAVE)
			.count(),
		1
	);
	assert!(alpha_messages.next().await.unwrap().is_none());
	let (cancel, mut cancelled_messages, _) = subscribe(&client, &accepted, &mut requests, "cancel").await;
	let mut pending = Box::pin(cancel.leave());
	tokio::select! {_=goodbye_started.notified()=>{},_=&mut pending=>panic!("goodbye answered too early")};
	assert!(cancelled_messages.next().await.unwrap().is_none());
	drop(pending);
	assert!(matches!(
		cancel.leave().await,
		Err(Error::Membership(membership::Error::GoodbyeUnobserved))
	));
	goodbye.borrow_mut().take().unwrap().fulfill(&Argument::Void).unwrap();
	let (survivor, mut surviving_messages, _) = subscribe(&client, &accepted, &mut requests, "beta").await;
	for root in roots {
		accepted.release(root).unwrap();
	}
	accepted.close(PendingWork::Cancel).await.unwrap();
	assert!(surviving_messages.next().await.unwrap().is_none());
	assert!(survivor.kind().is_err());
	drop((
		alpha,
		beta,
		cancel,
		survivor,
		alpha_messages,
		beta_messages,
		cancelled_messages,
		surviving_messages,
	));
	drop(client);
	runtime.close(PendingWork::Cancel).await.unwrap();
	server.close().await.unwrap();
	host.close(PendingWork::Cancel).await.unwrap();
	serving.await.unwrap().unwrap();
}
