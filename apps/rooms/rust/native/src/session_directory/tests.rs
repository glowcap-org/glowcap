use super::*;
use crate::{
	documents::SessionDocuments,
	session_commands::{SessionCommands, SessionEvents},
	session_state::SessionView,
};
use glowcap::Runtime;
use glowcap::{tcp, Argument, Host, ListenerIdentity, PendingWork, Ref, RuntimeConfig, Session};
use rooms_application::directory::registration;
use rooms_application::session::checkpoint::reconciliation::Fact;
use rooms_application::{
	grants::Access,
	session::{
		checkpoint::{commands::Facts, Checkpoint, Routes},
		state::Change as StateChange,
	},
};
use rooms_glowcap::client::directory::Directory;
use rooms_glowcap::routes::CheckpointRoutes;
use serde_json::{json, Value};
use std::rc::Rc;
use std::{
	cell::{Cell, RefCell},
	future::{poll_fn, Future},
	task::Poll,
	time::Duration,
};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
const REGISTRATION: &str = "11111111-1111-4111-8111-111111111111";
struct Events;
impl SessionEvents for Events {
	async fn preparing(
		&mut self,
		_checkpoint: &rooms_application::session::checkpoint::Checkpoint,
	) -> Result<impl Sized + 'static, String> {
		Ok(())
	}

	fn facts(&self) -> impl Facts {}
	fn changed(&mut self, _: StateChange, _: &SessionView) {}
	fn reconciliation_issue(&mut self, _: &Fact, error: Option<&str>) {
		assert!(error.is_none(), "{error:?}")
	}
}
struct Temp(std::path::PathBuf);
impl Drop for Temp {
	fn drop(&mut self) {
		std::fs::remove_dir_all(&self.0).unwrap();
	}
}
fn text<const N: usize, const E: bool>(s: &str) -> rooms_application::fields::Text<N, E> {
	rooms_application::fields::Text::new(s.into()).unwrap()
}
struct Peer {
	session: Rc<Session>,
	root: Ref,
	watcher: Rc<RefCell<Option<Ref>>>,
	inbox: Rc<RefCell<Option<Ref>>>,
	registrations: Rc<Cell<usize>>,
	arrived: mpsc::Receiver<()>,
	serving: JoinHandle<glowcap::Result<()>>,
}
async fn peer(server: &tcp::Server) -> Peer {
	let session = Rc::new(server.accept().await.unwrap().with_gc());
	let watcher = Rc::new(RefCell::new(None));
	let inbox = Rc::new(RefCell::new(None));
	let registrations = Rc::new(Cell::new(0));
	let (arrive, arrived) = mpsc::channel(2);
	let name = session
		.spawn_owned(|verb, _| {
			assert_eq!(verb, "voucher");
			Ok(Argument::Bytes(vec![4, 5, 6]))
		})
		.unwrap();
	let (service, watch, notify, count) = (session.clone(), watcher.clone(), inbox.clone(), registrations.clone());
	let root = session
		.publish("directory", move |verb, args| match verb {
			"listPublications" => Ok(Argument::List(vec![Argument::List(vec!["garden".into(), 1.into()])])),
			"watchPublications" => {
				let Argument::Reference(target) = &args[0] else {
					panic!("watch callback")
				};
				*watch.borrow_mut() = Some(target.clone());
				service
					.tell(target, "notify", &["opened".into(), "workshop".into(), 2.into()])
					.unwrap();
				Ok(Argument::List(vec![
					Argument::List(vec![Argument::List(vec!["garden".into(), 1.into()])]),
					Argument::List(vec![Argument::List(vec!["bob".into(), REGISTRATION.into()])]),
					0.into(),
				]))
			}
			"register" => {
				assert_eq!(args[0].as_str(), Some("alice"));
				assert_eq!(args[1].as_str(), Some("ocapn://member.id"));
				let Argument::Reference(target) = &args[2] else {
					panic!("name callback")
				};
				*notify.borrow_mut() = Some(target.clone());
				count.set(count.get() + 1);
				arrive.try_send(()).unwrap();
				Ok(name.clone().into())
			}
			_ => Err("unknown directory request".into()),
		})
		.unwrap();
	let serving = {
		let session = session.clone();
		tokio::task::spawn_local(async move { session.serve().await })
	};
	Peer {
		session,
		root,
		watcher,
		inbox,
		registrations,
		arrived,
		serving,
	}
}
#[tokio::test]
async fn concurrent_directories_retain_cancelled_startup_and_isolate_retirement() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(15), scenario())
				.await
				.expect("directory owner deadline");
		})
		.await;
}
async fn scenario() {
	let temp = Temp(std::env::temp_dir().join(format!("rooms-directory-owner-{}", std::process::id())));
	std::fs::create_dir(&temp.0).unwrap();
	let docs = SessionDocuments::open(&temp.0).await.unwrap().into_owners();
	drop((docs.grants, docs.bridge_secrets));
	let (commands, worker) = SessionCommands::open(docs.state, crate::client::Deadline)
		.await
		.unwrap();
	let worker = tokio::task::spawn_local(worker.run(Events));
	let runtime = Rc::new(
		Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
			.await
			.unwrap(),
	);
	let mut servers = Vec::new();
	let mut hosts = Vec::new();
	let mut ids = Vec::new();
	let mut checkpoint: Value = serde_json::from_str(&Checkpoint::empty().encode_for(Access::Admin).unwrap()).unwrap();
	for i in 0..2 {
		let host = Host::from_seed([100 + i; 32]).unwrap();
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
		let locator = glowcap::format_locator_uri(&server.locator().unwrap()).unwrap();
		let id = CheckpointRoutes.locator_authority(&locator).unwrap();
		checkpoint["directories"]
			.as_array_mut()
			.unwrap()
			.push(json!({"id":id,"locator":locator,"home":i==0,"nick":if i==0 {"alice"} else {""},"standing":null}));
		ids.push(text::<65536, true>(&id));
		servers.push(server);
		hosts.push(host);
	}
	commands
		.prepare_adoption(
			text("adopt"),
			0,
			Checkpoint::decode(&checkpoint.to_string(), &CheckpointRoutes).unwrap(),
		)
		.unwrap()
		.send()
		.unwrap()
		.wait()
		.await
		.unwrap();
	let register = || Register {
		member_locator: "ocapn://member.id".into(),
		voucher: None,
	};
	let connections = rooms_runtime::connections::Connections::new(runtime.clone(), Deadline);
	let mut first = DirectoryConnection::start(
		Source::Dial {
			connections: connections.clone(),
		},
		commands.clone(),
		&ids[0],
		register(),
	)
	.unwrap();
	let mut second = DirectoryConnection::start(
		Source::Dial {
			connections: connections.clone(),
		},
		commands.clone(),
		&ids[1],
		register(),
	)
	.unwrap();
	let (mut a, b) = tokio::join!(peer(&servers[0]), peer(&servers[1]));
	a.arrived.recv().await.unwrap();
	// A dropped ready observation does not drop or repeat the actual register.
	{
		let mut ready = Box::pin(first.ready());
		poll_fn(|cx| {
			assert!(ready.as_mut().poll(cx).is_pending());
			Poll::Ready(())
		})
		.await;
	}
	let notification = a.inbox.borrow().clone().unwrap();
	a.session
		.send(
			&notification,
			"notify",
			&["mintInboxFor".into(), "bob".into(), REGISTRATION.into()],
		)
		.await
		.unwrap();
	a.session
		.send(
			&notification,
			"notify",
			&["registered".into(), "alice".into(), REGISTRATION.into()],
		)
		.await
		.unwrap();
	let first_live = first.ready().await.unwrap();
	assert_eq!(first_live.nick(), "alice");
	let sibling = Directory::new(
		first_live.directory().client().clone(),
		first_live.directory().reference().clone(),
	);
	assert_eq!(first_live.take_voucher(), Some(vec![4, 5, 6]));
	assert!(first_live.take_voucher().is_none());
	assert!(first_live.view().peer(&"BOB".into()).is_some());
	let mut observed = (false, false);
	for _ in 0..2 {
		match first_live.next().await.unwrap().unwrap() {
			Event::Discovery(change) => {
				assert!(change.view && change.publications);
				observed.0 = true;
			}
			Event::Registration(event) => {
				assert_eq!(event.kind, registration::Kind::MintInboxFor);
				observed.1 = true;
			}
		}
	}
	assert_eq!(observed, (true, true));
	assert_eq!(first_live.view().snapshot(128).rooms.len(), 2);
	assert_eq!(a.registrations.get(), 1);
	let second_live = second.ready().await.unwrap();
	assert_eq!(second_live.nick(), "");
	let second_transport = second_live.directory().client().clone();
	assert!(second_live.take_voucher().is_none());
	assert_eq!(b.registrations.get(), 0);
	assert!(matches!(second_live.next().await.unwrap(), Some(Event::Discovery(_))));
	let committed: Value = commands
		.view()
		.read(|s| serde_json::from_str(&s.checkpoint().unwrap().encode_for(Access::Admin).unwrap()).unwrap())
		.unwrap();
	assert!(committed["directories"]
		.as_array()
		.unwrap()
		.iter()
		.all(|d| d["reached"] == true));
	let old_watch = a.watcher.borrow().clone().unwrap();
	first.close().await.unwrap();
	assert!(a
		.session
		.send(&old_watch, "notify", &["truncated".into(), 1.into()])
		.await
		.is_err());
	assert_eq!(sibling.list().await.unwrap()[0].name.text().as_str(), Some("garden"));
	let adopt = || Source::Adopt {
		directory: Directory::new(sibling.client().clone(), sibling.reference().clone()),
		nick: "alice".into(),
	};
	let mut cancelled = DirectoryConnection::start(adopt(), commands.clone(), &ids[0], register()).unwrap();
	tokio::select! { _=a.arrived.recv()=>{}, result=cancelled.ready()=>panic!("cancel startup before registration: {:?}", result.err()) };
	let cancelled_inbox = a.inbox.borrow().clone().unwrap();
	cancelled.close().await.unwrap();
	assert!(cancelled.ready().await.is_err());
	assert!(a
		.session
		.send(
			&cancelled_inbox,
			"notify",
			&["registered".into(), "alice".into(), REGISTRATION.into()]
		)
		.await
		.is_err());
	let revision = commands.view().read(|s| s.revision()).unwrap().unwrap();
	commands
		.prepare_command(
			text("request-nick"),
			revision,
			rooms_application::session::checkpoint::commands::Command::SetDirectoryNick,
			vec![ids[0].text().clone(), "requested".into()],
		)
		.unwrap()
		.send()
		.unwrap()
		.wait()
		.await
		.unwrap();
	// The adopted grant still registers alice, not the saved requested name.
	let mut stale = DirectoryConnection::start(adopt(), commands.clone(), &ids[0], register()).unwrap();
	tokio::select! { _=a.arrived.recv()=>{}, result=stale.ready()=>panic!("stale startup before registration: {:?}", result.err()) };
	let stale_inbox = a.inbox.borrow().clone().unwrap();
	let revision = commands.view().read(|s| s.revision()).unwrap().unwrap();
	commands
		.prepare_command(
			text("rename"),
			revision,
			rooms_application::session::checkpoint::commands::Command::SetDirectoryNick,
			vec![ids[0].text().clone(), "renamed".into()],
		)
		.unwrap()
		.send()
		.unwrap()
		.wait()
		.await
		.unwrap();
	a.session
		.send(
			&stale_inbox,
			"notify",
			&["registered".into(), "alice".into(), REGISTRATION.into()],
		)
		.await
		.unwrap();
	assert!(matches!(stale.ready().await,Err(error) if error.contains("intent changed")));
	assert!(stale.ready().await.is_err());
	assert_eq!(a.registrations.get(), 3);
	stale.close().await.unwrap();
	let watcher = b.watcher.borrow().clone().unwrap();
	b.session
		.send(&watcher, "notify", &["opened".into(), "after-close".into(), 1.into()])
		.await
		.unwrap();
	let second_live = second.ready().await.unwrap();
	assert!(matches!(second_live.next().await.unwrap(), Some(Event::Discovery(_))));
	assert!(second_live.view().room(&"after-close".into()).is_some());
	second.close().await.unwrap();
	commands.close().await.unwrap();
	worker.await.unwrap().unwrap();
	// Await both ends before dropping the final transport observation.
	for peer in [a, b] {
		peer.session.release(peer.root).unwrap();
		peer.session.close(PendingWork::Cancel).await.unwrap();
		peer.serving.await.unwrap().unwrap();
	}
	drop((sibling, second_transport));
	runtime.close(PendingWork::Cancel).await.unwrap();
	for server in servers {
		server.close().await.unwrap();
	}
	for host in hosts {
		host.close(PendingWork::Cancel).await.unwrap();
	}
}
