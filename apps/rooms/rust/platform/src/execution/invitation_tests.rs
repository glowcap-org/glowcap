//! Invitation clients keep a receipt across lost observations and let the
//! remote capability decide whether that claim still stands.
use super::HostPlatform;
use glowcap::{Argument, ConnectOptions, Host, ListenerIdentity, PendingWork, Runtime, RuntimeConfig, tcp};
use rooms_application::room::{
	invitation,
	policy::{MembershipKind, RoomPolicy},
};
use rooms_glowcap::client::{Client, Error, invitation::Invitation, room::Room};
use serde_json::{Value, json};
use std::{
	cell::{Cell, RefCell},
	future::Future,
	rc::Rc,
	time::Duration,
};

#[derive(Clone)]
struct Platform {
	bytes: Rc<Cell<[u8; 16]>>,
	entropy_failed: Rc<Cell<bool>>,
	timeout: Rc<Cell<bool>>,
}
impl rooms_glowcap::client::Entropy for Platform {
	fn invitation_receipt(&self) -> Result<invitation::Receipt, invitation::Error> {
		if self.entropy_failed.get() {
			return Err(invitation::Error::Entropy);
		}
		Ok(invitation::Receipt::from_entropy(self.bytes.get()))
	}
}
impl rooms_glowcap::client::Deadline for Platform {
	async fn within<T>(&self, milliseconds: u64, work: impl Future<Output = T>) -> Option<T> {
		if self.timeout.replace(false) {
			return None;
		}
		HostPlatform.within(milliseconds, work).await
	}
}
impl rooms_glowcap::client::Tasks for Platform {
	type Task = super::HostTask;
	fn spawn(&self, work: impl Future<Output = ()> + 'static) -> Self::Task {
		HostPlatform.spawn(work)
	}
}

#[tokio::test]
async fn invitation_receipts_survive_cancellation_and_room_queries_need_no_membership() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(10), scenario())
				.await
				.expect("invitation scenario deadline");
		})
		.await;
}
async fn scenario() {
	let host = Host::from_seed([85; 32]).unwrap();
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
	let fixture: Value =
		serde_json::from_str(include_str!("../../../proofs/fixtures/room-invitation-client.json")).unwrap();
	let bytes: [u8; 16] = serde_json::from_value(fixture["entropy"].clone()).unwrap();
	let platform = Platform {
		bytes: Rc::new(Cell::new(bytes)),
		entropy_failed: Rc::new(Cell::new(false)),
		timeout: Rc::new(Cell::new(false)),
	};
	let client = Client::new(connected.unwrap(), platform.clone());
	let calls = Rc::new(RefCell::new(Vec::<Value>::new()));
	let record = |target: &'static str, calls: Rc<RefCell<Vec<Value>>>| {
		move |verb: &str, args: &[Argument]| {
			calls.borrow_mut().push(
				json!({"target": target, "verb": verb, "args": args.iter().map(|v| json!(v.as_str())).collect::<Vec<_>>()}),
			);
		}
	};
	let entrance = accepted
		.spawn_owned(|verb, _| {
			assert_eq!(verb, "called");
			Ok("invited garden".into())
		})
		.unwrap();
	let active = Rc::new(Cell::new(true));
	let mode = Rc::new(Cell::new(0));
	let (tx, mut deferred) = tokio::sync::mpsc::channel(1);
	let claim_record = record("invitation", calls.clone());
	let (is_active, reply_mode, actor_host, entry) = (active.clone(), mode.clone(), host.clone(), entrance.clone());
	let winning = Rc::new(RefCell::new(None::<String>));
	let winner = winning.clone();
	let invitation_root = accepted
		.publish("invitation", move |verb, args| {
			claim_record(verb, args);
			assert_eq!(verb, "claimInvitation");
			assert_eq!(args.len(), 1);
			if !is_active.get() {
				return Err("this room invitation has ended".into());
			}
			let receipt = args[0].as_str().unwrap();
			assert_eq!(receipt.len(), 32);
			assert!(
				receipt
					.bytes()
					.all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
			);
			if winner.borrow().as_ref().is_some_and(|old| old != receipt) {
				return Err("this room invitation was claimed already".into());
			}
			*winner.borrow_mut() = Some(receipt.into());
			match reply_mode.get() {
				1 => {
					tx.try_send(actor_host.defer_turn().unwrap()).unwrap();
					Ok(Argument::Void)
				}
				2 => Ok(Argument::List(vec![entry.clone().into()])),
				_ => Ok(entry.clone().into()),
			}
		})
		.unwrap();
	let mint_mode = Rc::new(Cell::new(false));
	let (bad_mint, invitation_ref) = (mint_mode.clone(), invitation_root.clone());
	let seat_record = record("seat", calls.clone());
	let seat = accepted
		.spawn_owned(move |verb, args| {
			seat_record(verb, args);
			match verb {
				"mintInvitation" => {
					assert_eq!(args.len(), 1);
					assert!(matches!(args[0].as_str(), Some("observer" | "participant")));
					if bad_mint.get() {
						Ok(Argument::List(vec![invitation_ref.clone().into()]))
					} else {
						Ok(invitation_ref.clone().into())
					}
				}
				"leave" => Ok(Argument::Void),
				_ => Err("unexpected membership verb".into()),
			}
		})
		.unwrap();
	let query_reply = Rc::new(RefCell::new(None::<Argument>));
	let service = accepted.clone();
	let (member, override_reply) = (seat.clone(), query_reply.clone());
	let root = accepted
		.publish("room", move |verb, args| {
			if verb != "subscribe" {
				assert!(args.is_empty());
				if let Some(reply) = override_reply.borrow().as_ref() {
					return Ok(reply.clone());
				}
			}
			match verb {
				"called" => Ok("garden".into()),
				"private" => Ok("private".into()),
				"roomPolicy" => Ok(Argument::List(RoomPolicy::Private.modes().map(Argument::from).into())),
				"subscribe" => {
					let Argument::Reference(inbox) = &args[1] else {
						panic!("missing inbox")
					};
					service
						.tell(
							inbox,
							"notify",
							&["room".into(), "".into(), "listed".into(), false.into()],
						)
						.unwrap();
					Ok(Argument::List(vec![
						member.clone().into(),
						"participant".into(),
						Argument::Void,
						Argument::Void,
					]))
				}
				_ => Err("unexpected room verb".into()),
			}
		})
		.unwrap();
	let other = accepted
		.publish("other", |verb, args| {
			assert!(args.is_empty());
			match verb {
				"called" => Ok("square".into()),
				"private" => Ok(false.into()),
				"roomPolicy" => Ok(Argument::List(RoomPolicy::Open.modes().map(Argument::from).into())),
				_ => Err("unexpected other room verb".into()),
			}
		})
		.unwrap();
	let reference = client.session().fetch("room").await.unwrap();
	let other_ref = client.session().fetch("other").await.unwrap();
	assert_eq!(client.room_called(&reference).await.unwrap(), "garden");
	assert!(client.room_is_private(&reference).await.unwrap());
	assert_eq!(client.room_policy(&reference).await.unwrap(), RoomPolicy::Private);
	assert_eq!(client.room_called(&other_ref).await.unwrap(), "square");
	assert!(!client.room_is_private(&other_ref).await.unwrap());
	assert_eq!(client.room_policy(&other_ref).await.unwrap(), RoomPolicy::Open);
	*query_reply.borrow_mut() = Some(Argument::List(vec![entrance.clone().into()]));
	assert_eq!(client.room_called(&reference).await.unwrap(), "");
	assert!(matches!(client.room_is_private(&reference).await, Err(Error::Query(_))));
	assert!(matches!(client.room_policy(&reference).await, Err(Error::Query(_))));
	*query_reply.borrow_mut() = None;
	let (room, _messages) = Room::subscribe(client.clone(), reference, "alice", Default::default())
		.await
		.unwrap();
	assert_eq!(room.called().await.unwrap(), "garden");
	assert!(room.is_private().await.unwrap());
	assert_eq!(room.policy().await.unwrap(), RoomPolicy::Private);
	let minted = room.invite(MembershipKind::Observer).await.unwrap();
	let claimed = minted.claim().await.unwrap();
	assert_eq!(client.room_called(&claimed).await.unwrap(), "invited garden");
	minted.claim().await.unwrap();
	room.invite(MembershipKind::Participant).await.unwrap();
	room.leave().await.unwrap();
	active.set(false);
	assert!(
		minted
			.claim()
			.await
			.unwrap_err()
			.to_string()
			.contains("invitation has ended")
	);
	let received = Invitation::new(client.clone(), client.session().fetch("invitation").await.unwrap()).unwrap();
	assert!(received.claim().await.is_err());
	assert_eq!(json!(*calls.borrow()), fixture["calls"]);
	assert_eq!(room.called().await.unwrap(), "garden");
	assert!(matches!(
		room.invite(MembershipKind::Observer).await,
		Err(Error::Membership(_))
	));
	// Reply controls now exercise observation loss. The production server owns
	// retirement; resetting this fixture does not specify revival semantics.
	active.set(true);
	mode.set(1);
	let mut pending = Box::pin(minted.claim());
	let mut resolver = tokio::select! { r = deferred.recv() => r.unwrap(), _ = &mut pending => panic!("claim answered before resolver") };
	drop(pending);
	mode.set(0);
	let retry = minted.claim().await.unwrap();
	assert_eq!(client.room_called(&retry).await.unwrap(), "invited garden");
	// The Host's off-turn resolver settles plain data or a break; authority
	// replies use its forwarding surface. End this abandoned observation after
	// the retry has already received its real entrance capability.
	resolver.break_with("abandoned claim observation").unwrap();
	platform.timeout.set(true);
	assert!(matches!(minted.claim().await, Err(Error::Timeout(_))));
	assert!(minted.claim().await.is_ok());
	assert_eq!(
		winning.borrow().as_deref(),
		Some(invitation::Receipt::from_entropy(bytes).as_str())
	);
	platform.bytes.set([255; 16]);
	let competing = Invitation::new(client.clone(), client.session().fetch("invitation").await.unwrap()).unwrap();
	assert!(
		competing
			.claim()
			.await
			.unwrap_err()
			.to_string()
			.contains("claimed already")
	);
	mode.set(2);
	assert!(matches!(
		minted.claim().await,
		Err(Error::Invitation(invitation::Error::Entrance))
	));
	mode.set(0);
	assert!(minted.claim().await.is_ok());
	let (fresh, _messages) = Room::subscribe(
		client.clone(),
		client.session().fetch("room").await.unwrap(),
		"alice",
		Default::default(),
	)
	.await
	.unwrap();
	let before = calls.borrow().len();
	platform.entropy_failed.set(true);
	assert!(matches!(
		fresh.invite(MembershipKind::Participant).await,
		Err(Error::Invitation(invitation::Error::Entropy))
	));
	assert_eq!(calls.borrow().len(), before, "entropy failure must precede mint");
	assert!(matches!(
		Invitation::new(client.clone(), client.session().fetch("invitation").await.unwrap()),
		Err(Error::Invitation(invitation::Error::Entropy))
	));
	platform.entropy_failed.set(false);
	mint_mode.set(true);
	assert!(matches!(
		fresh.invite(MembershipKind::Participant).await,
		Err(Error::Invitation(invitation::Error::Invitation))
	));
	fresh.leave().await.unwrap();
	drop((
		fresh, room, minted, received, competing, claimed, retry, other_ref, client,
	));
	for reference in [root, other, invitation_root] {
		accepted.release(reference).unwrap();
	}
	drop((seat, entrance));
	accepted.close(PendingWork::Cancel).await.unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
	server.close().await.unwrap();
	host.close(PendingWork::Cancel).await.unwrap();
	serving.await.unwrap().unwrap();
}
