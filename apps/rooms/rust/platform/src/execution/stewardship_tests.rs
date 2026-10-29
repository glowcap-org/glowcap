use super::HostPlatform;
use glowcap::{
	Argument, CaptpVersion, ConnectOptions, Host, ListenerIdentity, PendingWork, Runtime, RuntimeConfig, tcp,
};
use rooms_application::room::authority;
use rooms_application::room::stewardship::{Error as CustodyError, Kind};
use rooms_glowcap::client::stewardship::Stewardship;
use rooms_glowcap::client::{Client, Error};
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
};

#[tokio::test]
async fn stewardship_keeps_rooms_isolated_and_rejects_late_authority() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let host = Host::from_seed([82; 32]).unwrap();
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
			let mode = Rc::new(Cell::new(0));
			let hold = Rc::new(Cell::new(false));
			let saved: Rc<RefCell<Option<glowcap::Resolver>>> = Rc::new(RefCell::new(None));
			let started = Rc::new(tokio::sync::Notify::new());
			let kicks = Rc::new(RefCell::new(Vec::new()));
			for name in ["alpha", "beta"] {
				let room_link = link(name);
				let identity = authority::room_identity(name).unwrap();
				let steward_link = link(&format!("steward-{name}"));
				let room_answer = room_link.clone();
				host.publish(name, move || {
					Box::new(move |verb, _| match verb.ok_or("fixture requires a method")? {
						authority::LINK => Ok(room_answer.clone().into()),
						authority::MANAGED_IDENTITY => Ok(name.into()),
						_ => Err("unexpected room call".into()),
					})
				})
				.unwrap();
				let grant_mode = mode.clone();
				let grant_identity = identity.clone();
				host.publish(&format!("manager-{name}"), move || {
					Box::new(move |verb, _| match verb.ok_or("fixture requires a method")? {
						authority::GOVERNS => Ok(name.into()),
						authority::LINK => Ok(room_link.clone().into()),
						authority::GIVE_STEWARD => match grant_mode.get() {
							1 => Err("not-steward: unavailable".into()),
							2 => Err("storage failed".into()),
							_ => Ok(Argument::List(vec![
								room_link.clone().into(),
								grant_identity.clone().into(),
								steward_link.clone().into(),
							])),
						},
						_ => Err("unexpected manager call".into()),
					})
				})
				.unwrap();
				for suffix in ["", "-next"] {
					let (identity, kicks, hold, saved, started, actor_host) = (
						identity.clone(),
						kicks.clone(),
						hold.clone(),
						saved.clone(),
						started.clone(),
						host.clone(),
					);
					host.publish(&format!("steward-{name}{suffix}"), move || {
						Box::new(move |verb, args| match verb.ok_or("fixture requires a method")? {
							authority::GOVERNS if hold.get() => {
								*saved.borrow_mut() = Some(actor_host.defer_turn().unwrap());
								started.notify_one();
								Ok(Argument::Void)
							}
							authority::GOVERNS => Ok(identity.clone().into()),
							authority::KICK => {
								assert_eq!(args.len(), 1);
								kicks.borrow_mut().push((name, args[0].as_str().unwrap().to_owned()));
								Ok(Argument::Void)
							}
							_ => Err("unexpected steward call".into()),
						})
					})
					.unwrap();
				}
			}
			let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
				.await
				.unwrap();
			let (session, accepted) =
				tokio::join!(runtime.connect(&locator, ConnectOptions::default()), server.accept());
			let accepted = accepted.unwrap();
			let serving = tokio::task::spawn_local(async move { accepted.serve().await });
			let client = Client::new(session.unwrap(), HostPlatform);
			let alpha = Stewardship::new(client.clone(), client.session().fetch("alpha").await.unwrap());
			let beta = Stewardship::new(client.clone(), client.session().fetch("beta").await.unwrap());
			assert!(!alpha.claim().await.unwrap());
			alpha.take_manager(&link("manager-alpha")).await.unwrap();
			mode.set(1);
			assert!(!alpha.claim().await.unwrap());
			mode.set(2);
			assert!(matches!(alpha.claim().await, Err(Error::Binding(_))));
			mode.set(0);
			assert!(alpha.claim().await.unwrap());
			beta.take(&link("steward-beta")).await.unwrap();
			assert!(matches!(
				alpha.take(&link("steward-beta")).await,
				Err(Error::Reply(authority::Refusal::StewardMismatch))
			));
			assert!(alpha.held() && beta.held());
			assert!(matches!(
				alpha.take(&link("missing")).await,
				Err(Error::Custody(CustodyError::StewardRetired))
			));
			alpha.kick("alice").await.unwrap();
			beta.kick("bob").await.unwrap();
			assert_eq!(*kicks.borrow(), vec![("alpha", "alice".into()), ("beta", "bob".into())]);
			alpha.forget(Kind::Steward, "old-generation");
			assert!(alpha.held());
			// The pending operation keeps its seat until its observation ends,
			// even after a pushed notice has invalidated the result.
			hold.set(true);
			let next = link("steward-alpha-next");
			let mut pending = Box::pin(alpha.take(&next));
			tokio::select! { _=started.notified()=>{}, result=&mut pending=>panic!("unexpected completion: {result:?}") }
			assert!(matches!(alpha.link().await, Err(Error::Custody(CustodyError::Busy))));
			alpha.forget(Kind::Steward, "steward-alpha");
			assert!(!alpha.held() && beta.held());
			saved
				.borrow_mut()
				.take()
				.unwrap()
				.fulfill(&authority::room_identity("alpha").unwrap().into())
				.unwrap();
			assert!(matches!(pending.await, Err(Error::Custody(CustodyError::Retired))));
			// Cancellation drops the acquisition ticket; the late binding answer
			// still retires without restoring application authority.
			let mut pending = Box::pin(alpha.take(&next));
			tokio::select! { _=started.notified()=>{}, result=&mut pending=>panic!("unexpected completion: {result:?}") }
			drop(pending);
			hold.set(false);
			saved
				.borrow_mut()
				.take()
				.unwrap()
				.fulfill(&authority::room_identity("alpha").unwrap().into())
				.unwrap();
			alpha.take(&next).await.unwrap();
			alpha.release();
			assert!(!alpha.held());
			assert_eq!(alpha.links().steward.as_deref(), Some(next.as_str()));
			alpha.take(&next).await.unwrap();
			alpha.forget(Kind::Room, "alpha");
			assert!(alpha.links().room.is_none() && alpha.links().steward.is_none());
			assert!(alpha.links().manager.is_some());
			assert!(matches!(
				alpha.kick("alice").await,
				Err(Error::Custody(CustodyError::StewardRetired))
			));
			drop(alpha);
			beta.kick("still-live").await.unwrap();
			drop(beta);
			drop(client);
			runtime.close(PendingWork::Cancel).await.unwrap();
			server.close().await.unwrap();
			host.close(PendingWork::Cancel).await.unwrap();
			serving.await.unwrap().unwrap();
		})
		.await;
}
