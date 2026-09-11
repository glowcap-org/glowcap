use super::*;
use crate::client::Deadline;
use glowcap::{tcp, ConnectOptions, Host, ListenerIdentity, PendingWork, Runtime, RuntimeConfig};
use glowcap::{Argument, Session};
use rooms_application::archive::{index::Index, Access, Body, ConversationKind, Coordinates, LineState};
use rooms_application::archive::{index::Page, Facet, Filter, Record};
use rooms_application::room::ArgumentView;
use rooms_glowcap::archive as wire;
use rooms_glowcap::client::{archive::Archive as ClientArchive, Client};
use rooms_glowcap::Value;
use std::time::Duration;
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
};
use tokio::sync::mpsc;
struct Memory {
	index: Rc<RefCell<Index>>,
	gate: Rc<tokio::sync::Notify>,
	blocked: Rc<Cell<bool>>,
	started: mpsc::Sender<()>,
	malformed: Rc<Cell<bool>>,
}
impl Backend for Memory {
	async fn put(&mut self, record: Record) -> Result<u64, String> {
		self.started.try_send(()).unwrap();
		if self.malformed.get() {
			return Ok(0);
		}
		if self.blocked.get() {
			self.gate.notified().await;
		}
		let mut index = self.index.borrow_mut();
		let revision = index.revision() + 1;
		index.apply(revision, record).map_err(|e| e.to_string())?;
		Ok(revision)
	}
	async fn read(&mut self, filter: &Filter, after: u64, limit: usize) -> Result<Page, String> {
		if self.malformed.get() {
			return Ok(Page {
				next: 1 << 53,
				more: false,
				records: vec![],
			});
		}
		self.index
			.borrow()
			.read(filter, after, limit)
			.map_err(|e| e.to_string())
	}
}
fn record() -> Record {
	Record::new(
		Coordinates {
			source: "recorder".into(),
			generation: "generation".into(),
			id: "one".into(),
		},
		"directory".into(),
		Body::Line {
			conversation_kind: ConversationKind::Room,
			conversation: "garden".into(),
			from: "alice".into(),
			text: "kept".into(),
			mine: false,
			at: 1,
			order: 1,
			state: LineState::Present,
			attachments: vec![],
		},
	)
	.unwrap()
}
#[tokio::test]
async fn hosting_drains_admitted_storage_and_bounds_facet_issuance() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(15), scenario())
				.await
				.expect("archive hosting deadline")
		})
		.await;
}
async fn scenario() {
	let host = Host::from_seed([198; 32]).unwrap();
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
	let accepted = Rc::new(accepted.unwrap().with_gc());
	let service = accepted.clone();
	let serving = tokio::task::spawn_local(async move { service.serve().await });
	let client = Client::new(connected.unwrap(), Deadline);
	let index = Rc::new(RefCell::new(Index::new(5000).unwrap()));
	let gate = Rc::new(tokio::sync::Notify::new());
	let blocked = Rc::new(Cell::new(false));
	let (started, mut starts) = mpsc::channel(128);
	let malformed = Rc::new(Cell::new(false));
	let (owner, worker) = Archive::new(
		crate::client::Deadline,
		Memory {
			index: index.clone(),
			gate: gate.clone(),
			blocked: blocked.clone(),
			started,
			malformed: malformed.clone(),
		},
	);
	let task = tokio::task::spawn_local(worker.run());
	let root = owner
		.receiver()
		.spawn(&accepted, Facet::new(Filter::default(), Access::ReadWrite).unwrap())
		.unwrap();
	let target = root.clone();
	let publication = accepted
		.publish("archive", move |_, _| Ok(target.clone().into()))
		.unwrap();
	let reference = client
		.session()
		.send(&client.session().fetch("archive").await.unwrap(), "root", &[])
		.await
		.unwrap();
	let Argument::Reference(reference) = reference else {
		panic!("archive reference")
	};
	let archive = ClientArchive::new(client.clone(), reference.clone());
	assert_eq!(archive.put(&record()).await.unwrap(), 1);
	starts.recv().await.unwrap();
	assert_eq!(archive.read_all(&Filter::default()).await.unwrap().len(), 1);
	let scope = Filter {
		conversation: Some("garden".into()),
		..Default::default()
	};
	let first = archive.narrow(&scope, Access::Read).await.unwrap();
	assert!(first.put(&record()).await.is_err());
	assert!(first.narrow(&Filter::default(), Access::ReadWrite).await.is_err());
	// Issuance is shared by descendants and survives dropping old occurrences.
	let child = first.narrow(&Filter::default(), Access::Read).await.unwrap();
	drop((first, child));
	for _ in 2..256 {
		drop(archive.narrow(&scope, Access::Read).await.unwrap());
	}
	assert!(archive.narrow(&scope, Access::Read).await.is_err());
	assert_eq!(archive.read_all(&Filter::default()).await.unwrap().len(), 1);
	// Independent peers need independent Runtime identities; a second dial
	// from the already-connected Host may be refused before accept yields.
	let runtime2 = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let (connected2, accepted2) =
		tokio::try_join!(runtime2.connect(&locator, ConnectOptions::default()), server.accept()).unwrap();
	let accepted2 = Rc::new(accepted2.with_gc());
	assert!(!accepted.same_session(&accepted2));
	let service2 = accepted2.clone();
	let serving2 = tokio::task::spawn_local(async move { service2.serve().await });
	let target2 = root.clone();
	let publication2 = accepted2
		.publish("archive", move |_, _| Ok(target2.clone().into()))
		.unwrap();
	let client2 = Client::new(connected2, Deadline);
	let returned = client2
		.session()
		.send(&client2.session().fetch("archive").await.unwrap(), "root", &[])
		.await
		.unwrap();
	let Argument::Reference(reference2) = returned else {
		panic!("second archive")
	};
	let archive2 = ClientArchive::new(client2.clone(), reference2);
	drop(archive2.narrow(&scope, Access::Read).await.unwrap());
	// A second connection has an independent lifetime issuance budget.
	assert!(archive.narrow(&scope, Access::Read).await.is_err());
	drop(archive2);
	client2.session().close(PendingWork::Cancel).await.unwrap();
	drop(client2);
	accepted2.release(publication2).unwrap();
	accepted2.close(PendingWork::Cancel).await.unwrap();
	serving2.await.unwrap().unwrap();
	runtime2.close(PendingWork::Cancel).await.unwrap();
	malformed.set(true);
	assert!(archive.put(&record()).await.is_err());
	starts.recv().await.unwrap();
	assert!(archive.read(&Filter::default(), 0, 1).await.is_err());
	malformed.set(false);
	// Hold the first backend operation, then fill every admitted slot. Reads
	// cannot overtake an earlier put, and pressure refuses before deferring.
	blocked.set(true);
	let first = client.session().send(&reference, "put", &[wire::record_row(&record())]);
	starts.recv().await.unwrap();
	let mut pending = Vec::new();
	for _ in 1..REQUEST_LIMIT {
		pending.push(client.session().send(
			&reference,
			"read",
			&[wire::filter_row(&Filter::default()).unwrap(), 0.into(), 1.into()],
		));
	}
	// A later synchronous call is an ordering barrier for earlier deliveries.
	assert!(client.session().send(&reference, "unknown", &[]).await.is_err());
	assert_eq!(owner.usage().requests, REQUEST_LIMIT);
	assert!(archive.read(&Filter::default(), 0, 1).await.is_err());
	let mut closing = Box::pin(owner.close());
	assert!(tokio::time::timeout(Duration::from_millis(5), &mut closing)
		.await
		.is_err());
	drop(closing);
	assert!(archive.read(&Filter::default(), 0, 1).await.is_err());
	blocked.set(false);
	gate.notify_one();
	assert_eq!(Value(&first.await.unwrap()).integer(), Some(2));
	for read in pending {
		read.await.unwrap();
	}
	let report = owner.close().await.unwrap();
	assert_eq!(report.refused, 2);
	assert_eq!(report.completed, 67);
	assert_eq!(report.reply_failures, 0);
	assert_eq!(task.await.unwrap(), report);
	assert_eq!(index.borrow().revision(), 2);
	assert!(client.session().is_open());
	assert!(accepted.is_open());
	retirement(&accepted).await;
	drop((archive, reference, owner, root));
	accepted.release(publication).unwrap();
	client.session().close(PendingWork::Cancel).await.unwrap();
	drop(client);
	accepted.close(PendingWork::Cancel).await.unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
	server.close().await.unwrap();
	host.close(PendingWork::Cancel).await.unwrap();
	serving.await.unwrap().unwrap();
}

struct Unused;
impl Backend for Unused {
	async fn put(&mut self, _: Record) -> Result<u64, String> {
		panic!("retired archive reached storage")
	}
	async fn read(&mut self, _: &Filter, _: u64, _: usize) -> Result<Page, String> {
		panic!("retired archive reached storage")
	}
}
async fn retirement(session: &Session) {
	let (owner, worker) = Archive::new(crate::client::Deadline, Unused);
	let receiver = owner.receiver();
	let reference = receiver
		.spawn(session, Facet::new(Filter::default(), Access::ReadWrite).unwrap())
		.unwrap();
	drop(worker);
	assert!(owner.close().await.is_err());
	assert!(session
		.send(&reference, "put", &[wire::record_row(&record())])
		.await
		.is_err());
	assert!(receiver
		.spawn(session, Facet::new(Filter::default(), Access::Read).unwrap())
		.is_err());
	drop((reference, owner));
	let (owner, worker) = Archive::new(crate::client::Deadline, Unused);
	let reference = owner
		.receiver()
		.spawn(session, Facet::new(Filter::default(), Access::ReadWrite).unwrap())
		.unwrap();
	drop(owner);
	assert!(session
		.send(&reference, "put", &[wire::record_row(&record())])
		.await
		.is_err());
	assert_eq!(worker.run().await, Report::default());
	assert!(session.is_open());
}
