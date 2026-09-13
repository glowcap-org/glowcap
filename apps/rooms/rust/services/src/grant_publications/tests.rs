use super::*;
use crate::documents::SessionDocuments;
use glowcap::{Argument, Host};
use glowcap::{ConnectOptions, ListenerIdentity, PendingWork, Runtime, RuntimeConfig, Session, tcp};
use rooms_application::grants::{Access, PolicyPatch, Rights};
use rooms_application::grants::{Change, Command, derive_entropy};
use std::rc::Rc;
use std::{
	fs,
	path::PathBuf,
	sync::atomic::{AtomicU64, Ordering},
	time::Duration,
};

const ID: &str = "00000000-0000-4000-8000-000000000001";
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp {
	fn new() -> Self {
		let path = std::env::temp_dir().join(format!(
			"rooms-publications-{}-{}",
			std::process::id(),
			NEXT.fetch_add(1, Ordering::Relaxed)
		));
		fs::create_dir(&path).unwrap();
		Self(path)
	}
}
impl Drop for Temp {
	fn drop(&mut self) {
		fs::remove_dir_all(&self.0).unwrap();
	}
}

fn behavior() -> GrantedBehavior {
	Box::new(|authority, grant, verb, args| {
		if !args.is_empty() {
			return Err("fixture takes no arguments".into());
		}
		match verb {
			"historyReader" if grant.history() => {
				let authority = authority.clone();
				let session = glowcap::current_session()
					.map_err(|error| error.to_string())?
					.ok_or("reader requires a session")?;
				Ok(session
					.spawn(move |verb, args| {
						if verb != "read" || !args.is_empty() {
							return Err("reader takes read".into());
						}
						if !authority
							.read(|grant| grant.access() != Access::None && grant.history())
							.map_err(rooms_runtime::Error::into_refusal)?
						{
							return Err("history permission ended".into());
						}
						Ok("history".into())
					})
					.map_err(|error| error.to_string())?
					.into())
			}
			"access" => Ok(format!("{:?}/{}", grant.access(), grant.history()).into()),
			"write" if matches!(grant.access(), Access::Interact | Access::Admin) => Ok("written".into()),
			_ => Err("grant does not admit this operation".into()),
		}
	})
}

async fn owner(temp: &Temp, name: &str, host: &Host, root: u8) -> PublishedGrants {
	let mut docs = SessionDocuments::open(temp.0.join(name)).await.unwrap();
	let grants = docs.take_grants().unwrap();
	let mut owner = PublishedGrants::new(grants, host.clone(), [root; 16], behavior);
	owner.restore().await.unwrap();
	owner
}
fn issue() -> Command {
	Command::Issue {
		id: ID.into(),
		rights: Rights::Interact,
		label: "Phone".into(),
		history: false,
	}
}
async fn pair(server: &tcp::Server, runtime: &Runtime) -> (Session, tokio::task::JoinHandle<glowcap::Result<()>>) {
	let locator = server.locator().unwrap();
	let (client, accepted) = tokio::join!(runtime.connect(&locator, ConnectOptions::default()), server.accept());
	let accepted = accepted.unwrap().with_gc();
	(
		client.unwrap().with_gc(),
		tokio::task::spawn_local(async move { accepted.serve().await }),
	)
}

#[tokio::test]
async fn persisted_policy_controls_held_caps_across_sessions_and_restart() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(15), scenario())
				.await
				.expect("grant fixture progress");
		})
		.await;
}
async fn scenario() {
	let temp = Temp::new();
	let host = Host::from_seed([7; 32]).unwrap();
	let mut a = owner(&temp, "a", &host, 1).await;
	let mut b = owner(&temp, "b", &host, 2).await;
	a.apply(issue()).await.unwrap();
	b.apply(issue()).await.unwrap();
	let name = a.swiss(ID).unwrap().unwrap().to_owned();
	let other_name = b.swiss(ID).unwrap().unwrap().to_owned();
	assert_ne!(name, other_name);
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
	let (x, serving_x) = pair(&server, &runtime).await;
	let runtime_y = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let (y, serving_y) = pair(&server, &runtime_y).await;
	let held = x.fetch(&name).await.unwrap();
	let held_y = y.fetch(&name).await.unwrap();
	let other = y.fetch(&other_name).await.unwrap();
	assert_eq!(x.send(&held, "write", &[]).await.unwrap().as_str(), Some("written"));
	a.apply(Command::SetPolicy {
		id: ID.into(),
		patch: PolicyPatch {
			rights: Some(Rights::Observe),
			history: Some(true),
			..Default::default()
		},
	})
	.await
	.unwrap();
	assert!(x.send(&held, "write", &[]).await.is_err());
	assert_eq!(
		y.send(&held_y, "access", &[]).await.unwrap().as_str(),
		Some("Observe/true")
	);
	assert_eq!(y.send(&other, "write", &[]).await.unwrap().as_str(), Some("written"));
	let Argument::Reference(history_reader) = x.send(&held, "historyReader", &[]).await.unwrap() else {
		panic!("held history reader")
	};
	assert_eq!(
		x.send(&history_reader, "read", &[]).await.unwrap().as_str(),
		Some("history")
	);
	for history in [false, true] {
		a.apply(Command::SetPolicy {
			id: ID.into(),
			patch: PolicyPatch {
				history: Some(history),
				..Default::default()
			},
		})
		.await
		.unwrap();
		assert_eq!(x.send(&history_reader, "read", &[]).await.is_ok(), history);
	}

	a.apply(Command::SetPolicy {
		id: ID.into(),
		patch: PolicyPatch {
			suspended: Some(true),
			..Default::default()
		},
	})
	.await
	.unwrap();
	assert_eq!(x.send(&held, "access", &[]).await.unwrap().as_str(), Some("None/true"));
	assert!(x.send(&history_reader, "read", &[]).await.is_err());
	assert_eq!(a.swiss(ID).unwrap(), Some(name.as_str()));
	a.apply(Command::Revoke { id: ID.into() }).await.unwrap();
	assert!(x.send(&held, "access", &[]).await.is_err());
	assert!(y.send(&held_y, "access", &[]).await.is_err());
	assert!(x.send(&history_reader, "read", &[]).await.is_err());
	assert_eq!(a.swiss(ID).unwrap(), None);
	a.close().unwrap();
	b.close().unwrap();
	assert!(y.send(&other, "write", &[]).await.is_err());
	drop((a, b));
	server.close().await.unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
	runtime_y.close(PendingWork::Cancel).await.unwrap();
	host.close(PendingWork::Cancel).await.unwrap();
	serving_x.await.unwrap().unwrap();
	serving_y.await.unwrap().unwrap();
	let restored = Host::from_seed([7; 32]).unwrap();
	let mut docs_a = SessionDocuments::open(temp.0.join("a")).await.unwrap();
	let mut a = PublishedGrants::new(docs_a.take_grants().unwrap(), restored.clone(), [1; 16], behavior);
	a.restore().await.unwrap();
	assert_eq!(a.swiss(ID).unwrap(), None);
	assert!(a.apply(issue()).await.is_err());
	let mut docs_b = SessionDocuments::open(temp.0.join("b")).await.unwrap();
	let mut b = PublishedGrants::new(docs_b.take_grants().unwrap(), restored.clone(), [2; 16], behavior);
	b.restore().await.unwrap();
	assert_eq!(b.swiss(ID).unwrap(), Some(other_name.as_str()));
	a.close().unwrap();
	b.close().unwrap();
	restored.close(PendingWork::Cancel).await.unwrap();
}

#[tokio::test]
async fn publication_failure_keeps_committed_policy_and_retries_without_another_write() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let temp = Temp::new();
			let host = Host::from_seed([7; 32]).unwrap();
			let mut grants = owner(&temp, "a", &host, 1).await;
			let entropy = derive_entropy(&[1; 16], ID).unwrap();
			let collision = host
				.publish_durable_with_entropy(entropy, || Box::new(|_, _| Ok(Argument::Void)))
				.unwrap();
			assert!(matches!(
				grants.apply(issue()).await,
				Err(Error::Publication {
					change: Some(Change::Issued),
					..
				})
			));
			assert_eq!(grants.grants().unwrap().active_count().unwrap(), 1);
			assert!(matches!(grants.swiss(ID), Err(Error::NotPublished(_))));
			let disk = fs::read(temp.0.join("a/grants.json")).unwrap();
			host.remove_durable(&collision).unwrap();
			assert_eq!(grants.apply(issue()).await.unwrap(), Change::Unchanged);
			assert_eq!(grants.swiss(ID).unwrap(), Some(collision.as_str()));
			assert_eq!(fs::read(temp.0.join("a/grants.json")).unwrap(), disk);
			grants.close().unwrap();
			host.close(PendingWork::Cancel).await.unwrap();
		})
		.await;
}

#[tokio::test]
async fn close_in_a_callback_disables_held_authority_and_retains_cleanup_for_retry() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let temp = Temp::new();
			let host = Host::from_seed([7; 32]).unwrap();
			let slot = Rc::new(std::cell::RefCell::new(None::<PublishedGrants>));
			let weak = Rc::downgrade(&slot);
			let mut docs = SessionDocuments::open(temp.0.join("a")).await.unwrap();
			let mut grants = PublishedGrants::new(docs.take_grants().unwrap(), host.clone(), [1; 16], move || {
				let weak = weak.clone();
				Box::new(move |_, _, _, _| {
					let slot = weak.upgrade().unwrap();
					let mut owner = slot.borrow_mut();
					let result = owner.as_mut().unwrap().close();
					assert!(
						matches!(result, Err(Error::Publication { .. })),
						"host Host refuses reentrant removal"
					);
					Ok("closed".into())
				})
			});
			grants.restore().await.unwrap();
			grants.apply(issue()).await.unwrap();
			let name = grants.swiss(ID).unwrap().unwrap().to_owned();
			*slot.borrow_mut() = Some(grants);
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
			let (client, serving) = pair(&server, &runtime).await;
			let held = client.fetch(&name).await.unwrap();
			assert_eq!(client.send(&held, "close", &[]).await.unwrap().as_str(), Some("closed"));
			assert!(client.send(&held, "again", &[]).await.is_err());
			let mut grants = slot.borrow_mut().take().unwrap();
			assert!(client.fetch(&name).await.is_ok(), "failed cleanup remains registered");
			grants.close().unwrap();
			assert!(client.fetch(&name).await.is_err(), "retry removes the publication");
			grants.close().unwrap();
			server.close().await.unwrap();
			runtime.close(PendingWork::Cancel).await.unwrap();
			host.close(PendingWork::Cancel).await.unwrap();
			serving.await.unwrap().unwrap();
		})
		.await;
}

#[tokio::test]
async fn partial_restore_stays_closed_until_retry_and_drop_retires_held_caps() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let temp = Temp::new();
			let host = Host::from_seed([7; 32]).unwrap();
			let second = "00000000-0000-4000-8000-000000000002";
			let mut docs = SessionDocuments::open(temp.0.join("a")).await.unwrap();
			let mut durable = docs.take_grants().unwrap();
			durable.load().await.unwrap();
			durable.apply(issue()).await.unwrap();
			durable
				.apply(Command::Issue {
					id: second.into(),
					rights: Rights::Observe,
					label: "Tablet".into(),
					history: true,
				})
				.await
				.unwrap();
			let collision = host
				.publish_durable_with_entropy(derive_entropy(&[1; 16], second).unwrap(), || {
					Box::new(|_, _| Ok(Argument::Void))
				})
				.unwrap();
			let first_name = host
				.publish_durable_with_entropy(derive_entropy(&[1; 16], ID).unwrap(), || {
					Box::new(|_, _| Ok(Argument::Void))
				})
				.unwrap();
			host.remove_durable(&first_name).unwrap();
			let mut grants = PublishedGrants::new(durable, host.clone(), [1; 16], behavior);
			assert!(matches!(
				grants.restore().await,
				Err(Error::Publication { change: None, .. })
			));
			assert!(grants.swiss(ID).is_err());
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
			let (client, serving) = pair(&server, &runtime).await;
			let held = client.fetch(&first_name).await.unwrap();
			assert!(client.send(&held, "write", &[]).await.is_err());
			host.remove_durable(&collision).unwrap();
			grants.restore().await.unwrap();
			assert_eq!(grants.swiss(ID).unwrap(), Some(first_name.as_str()));
			assert_eq!(grants.swiss(second).unwrap(), Some(collision.as_str()));
			assert_eq!(
				client.send(&held, "write", &[]).await.unwrap().as_str(),
				Some("written")
			);
			drop(grants);
			assert!(client.send(&held, "write", &[]).await.is_err());
			server.close().await.unwrap();
			runtime.close(PendingWork::Cancel).await.unwrap();
			host.close(PendingWork::Cancel).await.unwrap();
			serving.await.unwrap().unwrap();
		})
		.await;
}
