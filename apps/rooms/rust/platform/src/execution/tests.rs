use super::*;
use glowcap::{
	Argument, CaptpVersion, ConnectOptions, Host, ListenerIdentity, PendingWork, Runtime, RuntimeConfig, tcp,
};
use rooms_application::room::{authority, policy::RoomPolicy};
use rooms_glowcap::client::{Client, Error, manager::Manager};
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
};

#[tokio::test]
async fn manager_client_validates_authority_and_executes_real_host_calls() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let host = Host::from_seed([81; 32]).unwrap();
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
			let locator = server.locator().unwrap();
			let link = |name: &str| glowcap::format_sturdyref(&locator, name.as_bytes(), CaptpVersion::V1_0).unwrap();
			let manager_link = link("manager");
			let room_link = link("room-link");
			let steward_link = link("steward");
			let correlator = authority::room_identity("room-link").unwrap();
			let invalid = Rc::new(Cell::new(false));
			let calls = Rc::new(RefCell::new(Vec::new()));
			let seen = calls.clone();
			host.publish("room", move || {
				let seen = seen.clone();
				Box::new(move |verb, args| {
					assert_eq!(verb, authority::MANAGED_IDENTITY);
					assert!(args.is_empty());
					seen.borrow_mut().push(verb.to_string());
					Ok("managed-id".into())
				})
			})
			.unwrap();
			for (name, identity) in [("manager", "managed-id"), ("wrong", "different-id")] {
				let (invalid, seen, room_link, steward_link, correlator) = (
					invalid.clone(),
					calls.clone(),
					room_link.clone(),
					steward_link.clone(),
					correlator.clone(),
				);
				host.publish(name, move || {
					let (invalid, seen, room_link, steward_link, correlator) = (
						invalid.clone(),
						seen.clone(),
						room_link.clone(),
						steward_link.clone(),
						correlator.clone(),
					);
					Box::new(move |verb, args| {
						seen.borrow_mut().push(verb.to_string());
						match verb {
							authority::GOVERNS => Ok(identity.into()),
							authority::LINK => Ok(room_link.clone().into()),
							authority::GIVE_STEWARD => Ok(Argument::List(vec![
								room_link.clone().into(),
								correlator.clone().into(),
								steward_link.clone().into(),
							])),
							authority::REVOKE_STEWARD | authority::REVOKE_ROOM_LINK => {
								assert_eq!(args.len(), 1);
								assert_eq!(args[0].as_str(), Some("exact-token"));
								Ok(Argument::Void)
							}
							authority::SET_POLICY => {
								assert_eq!(
									args.iter().map(|v| v.as_str().unwrap()).collect::<Vec<_>>(),
									["listed", "open", "moderated", "general"]
								);
								Ok(Argument::List(if invalid.get() {
									vec!["wrong".into()]
								} else {
									vec!["general".into(), "listed".into(), "open".into(), "moderated".into()]
								}))
							}
							authority::UNREGISTER_ROOM => {
								assert!(args.is_empty());
								Ok(Argument::List(vec![
									"general".into(),
									"secret".into(),
									"invite-only".into(),
									"moderated".into(),
								]))
							}
							_ => Err("unexpected manager operation".into()),
						}
					})
				})
				.unwrap();
			}
			let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
				.await
				.unwrap();
			let (session, accepted) =
				tokio::join!(runtime.connect(&locator, ConnectOptions::default()), server.accept());
			let accepted = accepted.unwrap();
			let serving = tokio::task::spawn_local(async move { accepted.serve().await });
			let client = Client::new(session.unwrap(), HostPlatform);
			let sibling = client.clone();
			let room = client.session().fetch("room").await.unwrap();
			assert!(matches!(
				Manager::take(&client, &room, &link("wrong")).await,
				Err(Error::Reply(authority::Refusal::ManagerMismatch))
			));
			let manager = Manager::take(&client, &room, &manager_link).await.unwrap();
			assert_eq!(manager.sturdyref(), manager_link);
			assert_eq!(manager.room_link().await.unwrap(), room_link);
			let grant = manager.give_steward().await.unwrap();
			assert_eq!(grant.room_link, room_link);
			assert_eq!(grant.steward_link, steward_link);
			assert_eq!(grant.room_identity, correlator);
			manager.revoke_steward("exact-token").await.unwrap();
			manager.revoke_room_link("exact-token").await.unwrap();
			let update = manager.set_policy(RoomPolicy::Moderated, "general").await.unwrap();
			assert_eq!(update.name, "general");
			assert_eq!(update.policy, RoomPolicy::Moderated);
			invalid.set(true);
			assert!(matches!(
				manager.set_policy(RoomPolicy::Moderated, "general").await,
				Err(Error::Reply(authority::Refusal::Policy))
			));
			let update = manager.unregister().await.unwrap();
			assert_eq!(update.name, "general");
			assert_eq!(update.policy, RoomPolicy::Private);
			drop(manager);
			drop(client);
			assert_eq!(
				Manager::take(&sibling, &room, &manager_link)
					.await
					.unwrap()
					.room_link()
					.await
					.unwrap(),
				room_link
			);
			assert!(calls.borrow().iter().any(|v| v == authority::UNREGISTER_ROOM));
			drop(room);
			drop(sibling);
			runtime.close(PendingWork::Cancel).await.unwrap();
			server.close().await.unwrap();
			host.close(PendingWork::Cancel).await.unwrap();
			serving.await.unwrap().unwrap();
		})
		.await;
}

#[tokio::test]
async fn native_deadline_drops_an_unanswered_observation() {
	use rooms_glowcap::client::Deadline as _;
	struct Dropped(Rc<Cell<bool>>);
	impl Drop for Dropped {
		fn drop(&mut self) {
			self.0.set(true);
		}
	}
	let dropped = Rc::new(Cell::new(false));
	let observed = Dropped(dropped.clone());
	let result = HostPlatform
		.within(1, async move {
			let _held = observed;
			core::future::pending::<()>().await
		})
		.await;
	assert!(result.is_none());
	assert!(dropped.get());
}
