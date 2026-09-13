use super::*;
use crate::documents::SessionDocuments;
use glowcap::{Argument, CaptpVersion, Host};
use glowcap::{ConnectOptions, ListenerIdentity, PendingWork, Runtime, RuntimeConfig, Session, tcp};
use rooms_application::grants::protocol::{self, GrantView};
use rooms_runtime::{documents::Document, grants::publications::PublishedGrants};
use std::{cell::Cell, rc::Rc};
use std::{
	cell::RefCell,
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
			"rooms-grant-commands-{}-{}",
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

struct Notices(Rc<RefCell<Vec<String>>>, bool);
impl GrantCommandEffects for Notices {
	fn local_reply_failed(&mut self, error: rooms_runtime::Error) {
		panic!("unexpected abandoned grant failure: {error}");
	}
	fn reply_failed(&mut self, error: glowcap::Error) {
		self.0.borrow_mut().push(format!("reply failed: {error}"));
	}
	async fn changed<D: Document>(
		&mut self,
		notice: GrantNotice<'_>,
		_grants: &PublishedGrants<D>,
	) -> Result<(), rooms_runtime::Error> {
		self.0.borrow_mut().push(match notice {
			GrantNotice::Committed { id, change } => format!("{id}: {change:?}"),
			GrantNotice::Unavailable => "closed".into(),
			GrantNotice::Routed => "routed".into(),
		});
		if core::mem::take(&mut self.1) {
			Err(rooms_runtime::Error::refused("fixture notice refusal"))
		} else {
			Ok(())
		}
	}
}

struct Harness {
	temp: Temp,
	host: Host,
	server: tcp::Server,
	runtime: Runtime,
	client: Session,
	serving: tokio::task::JoinHandle<glowcap::Result<()>>,
	commands: GrantCommands,
	root: glowcap::Ref,
	root_name: String,
	admitted: Rc<Cell<usize>>,
}
impl Harness {
	async fn open() -> (Self, GrantCommandWorker) {
		let temp = Temp::new();
		let host = Host::from_seed([7; 32]).unwrap();
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
		let mut docs = SessionDocuments::open(&temp.0).await.unwrap();
		let grants = docs.take_grants().unwrap();
		drop(docs);
		let (commands, worker) = GrantCommands::open(grants, host.clone(), [3; 16], locator.clone(), || {
			Box::new(|_authority, grant, verb, _| {
				if verb == "fixtureAccess" {
					Ok(format!("{:?}", grant.access()).into())
				} else {
					Err("unknown fixture method".into())
				}
			})
		})
		.await
		.unwrap();
		let admitted = Rc::new(Cell::new(0));
		let name = host
			.publish_durable_with_entropy([3; 16], || {
				let admitted = admitted.clone();
				let mut behavior = commands.admin_behavior();
				Box::new(move |verb, args| {
					let result = behavior(verb, args);
					if result.is_ok() {
						admitted.set(admitted.get() + 1);
					}
					result
				})
			})
			.unwrap();
		let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
			.await
			.unwrap();
		let (client, accepted) = tokio::join!(runtime.connect(&locator, ConnectOptions::default()), server.accept());
		let client = client.unwrap().with_gc();
		let accepted = accepted.unwrap().with_gc();
		let serving = tokio::task::spawn_local(async move { accepted.serve().await });
		let root = client.fetch(&name).await.unwrap();
		(
			Self {
				temp,
				host,
				server,
				runtime,
				client,
				serving,
				commands,
				root,
				root_name: name,
				admitted,
			},
			worker,
		)
	}
	async fn close(self) {
		self.server.close().await.unwrap();
		self.runtime.close(PendingWork::Cancel).await.unwrap();
		self.host.close(PendingWork::Cancel).await.unwrap();
		self.serving.await.unwrap().unwrap();
	}
}
fn issue() -> [Argument; 4] {
	[ID.into(), "interact".into(), "Phone".into(), false.into()]
}
fn view(reply: Argument) -> GrantView {
	GrantView::decode(reply.as_str().unwrap()).unwrap()
}

#[tokio::test]
async fn existing_wire_methods_use_live_policy_and_notify_before_reply() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let (h, worker) = Harness::open().await;
			let notices = Rc::new(RefCell::new(Vec::new()));
			let running = tokio::task::spawn_local(worker.run(Notices(notices.clone(), true)));
			let first = h
				.client
				.send(&h.root, protocol::ISSUE, &issue())
				.await
				.unwrap_err()
				.to_string();
			// The caller must learn the policy stands, or it issues a second
			// grant on retry, and the notice's own refusal stays readable behind it.
			assert!(
				first.contains("grant policy committed but attached views were not notified"),
				"{first}"
			);
			assert!(first.contains("fixture notice refusal"), "{first}");
			let issued = view(h.client.send(&h.root, protocol::ISSUE, &issue()).await.unwrap());
			assert_eq!(notices.borrow().len(), 2);
			let parsed = glowcap::parse_sturdyref(&issued.sturdyref, CaptpVersion::V1_0).unwrap();
			assert_eq!(parsed.locator, h.server.locator().unwrap());
			let held = h
				.client
				.fetch(core::str::from_utf8(&parsed.swissnum).unwrap())
				.await
				.unwrap();
			assert_eq!(
				h.client.send(&held, "fixtureAccess", &[]).await.unwrap().as_str(),
				Some("Interact")
			);
			assert!(h.client.send(&held, protocol::ISSUE, &issue()).await.is_err());
			let policy = [ID.into(), "admin".into(), true.into(), Argument::Void, Argument::Void];
			let updated = view(h.client.send(&h.root, protocol::SET_POLICY, &policy).await.unwrap());
			assert_eq!(issued.sturdyref, updated.sturdyref);
			assert!(updated.history);
			assert_eq!(notices.borrow().len(), 3);
			let next = [
				"00000000-0000-4000-8000-000000000002".into(),
				"observe".into(),
				"tablet".into(),
				true.into(),
			];
			assert!(h.client.send(&held, protocol::ISSUE, &next).await.is_ok());
			let bad = [Argument::List(vec![Argument::Reference(held.clone())])];
			assert!(h.client.send(&h.root, protocol::REVOKE, &bad).await.is_err());
			assert!(matches!(
				h.client.send(&h.root, protocol::REVOKE, &[ID.into()]).await.unwrap(),
				Argument::Void
			));
			assert!(h.client.send(&held, protocol::ISSUE, &next).await.is_err());
			h.commands.close().await.unwrap();
			h.commands.close().await.unwrap();
			running.await.unwrap().unwrap();
			assert_eq!(notices.borrow().last().unwrap(), "closed");
			h.close().await;
		})
		.await;
}

#[tokio::test]
async fn a_full_queue_refuses_before_deferral_and_close_drains_admitted_work() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let (h, worker) = Harness::open().await;
			let args = issue();
			let mut pending = Vec::new();
			for _ in 0..MAX_PENDING_GRANT_COMMANDS {
				pending.push(h.client.send(&h.root, protocol::ISSUE, &args));
			}
			tokio::time::timeout(Duration::from_secs(3), async {
				while h.admitted.get() != MAX_PENDING_GRANT_COMMANDS {
					tokio::task::yield_now().await;
				}
			})
			.await
			.unwrap();
			let error = h.client.send(&h.root, protocol::ISSUE, &args).await.unwrap_err();
			assert!(error.to_string().contains("queue is full"));
			let close = h.commands.close();
			let running = worker.run(Notices(Rc::new(RefCell::new(Vec::new())), false));
			let drain = async {
				for answer in pending {
					answer.await.unwrap();
				}
			};
			let (closed, stopped, ()) = tokio::join!(close, running, drain);
			closed.unwrap();
			stopped.unwrap();
			assert!(h.client.send(&h.root, protocol::ISSUE, &args).await.is_err());
			h.close().await;
		})
		.await;
}

struct BlockNotice(Option<tokio::sync::oneshot::Sender<()>>);

#[tokio::test]
async fn a_disconnected_caller_does_not_stop_admitted_work_for_other_connections() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let (h, worker) = Harness::open().await;
			let args = issue();
			let answer = h.client.send(&h.root, protocol::ISSUE, &args);
			tokio::time::timeout(Duration::from_secs(3), async {
				while h.admitted.get() == 0 {
					tokio::task::yield_now().await;
				}
			})
			.await
			.unwrap();
			h.client.close(PendingWork::Cancel).await.unwrap();
			while !h.serving.is_finished() {
				tokio::task::yield_now().await;
			}
			let notices = Rc::new(RefCell::new(Vec::new()));
			let running = tokio::task::spawn_local(worker.run(Notices(notices.clone(), false)));
			let locator = h.server.locator().unwrap();
			let (second, accepted) = tokio::join!(
				h.runtime.connect(&locator, ConnectOptions::default()),
				h.server.accept()
			);
			let second = second.unwrap();
			let accepted = accepted.unwrap();
			let serving = tokio::task::spawn_local(async move { accepted.serve().await });
			let root = second.fetch(&h.root_name).await.unwrap();
			let issued = view(second.send(&root, protocol::ISSUE, &args).await.unwrap());
			assert_eq!(issued.id, ID);
			assert!(notices.borrow().iter().any(|event| event.starts_with("reply failed:")));
			assert!(answer.await.is_err());
			h.commands.close().await.unwrap();
			running.await.unwrap().unwrap();
			h.close().await;
			serving.await.unwrap().unwrap();
		})
		.await;
}
impl GrantCommandEffects for BlockNotice {
	fn local_reply_failed(&mut self, error: rooms_runtime::Error) {
		panic!("unexpected abandoned grant failure: {error}");
	}
	fn reply_failed(&mut self, error: glowcap::Error) {
		panic!("unexpected reply failure: {error}");
	}
	async fn changed<D: Document>(
		&mut self,
		notice: GrantNotice<'_>,
		_: &PublishedGrants<D>,
	) -> Result<(), rooms_runtime::Error> {
		if matches!(notice, GrantNotice::Committed { .. }) {
			self.0.take().unwrap().send(()).unwrap();
			core::future::pending::<()>().await;
		}
		Ok(())
	}
}
#[tokio::test]
async fn cancelling_the_worker_retires_pending_replies_and_keeps_committed_disk_state() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let (h, worker) = Harness::open().await;
			let (started, waiting) = tokio::sync::oneshot::channel();
			let running = tokio::task::spawn_local(worker.run(BlockNotice(Some(started))));
			let args = issue();
			let reply = h.client.send(&h.root, protocol::ISSUE, &args);
			waiting.await.unwrap();
			running.abort();
			assert!(running.await.unwrap_err().is_cancelled());
			let refused = tokio::time::timeout(Duration::from_secs(3), reply)
				.await
				.unwrap()
				.unwrap_err();
			assert!(refused.to_string().contains("deferred reply owner was dropped"));
			let error = h.commands.close().await.unwrap_err();
			assert!(matches!(&error, rooms_runtime::Error::Closed(_)));
			assert!(error.to_string().contains("cancelled"));
			let mut docs = SessionDocuments::open(&h.temp.0).await.unwrap();
			let mut grants = docs.take_grants().unwrap();
			grants.load().await.unwrap();
			assert_eq!(grants.ledger().unwrap().active_count().unwrap(), 1);
			drop(grants);
			drop(docs);
			h.close().await;
		})
		.await;
}
