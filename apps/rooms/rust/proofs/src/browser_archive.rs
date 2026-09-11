//! Shared archive admission and share authority execute inside the linked Wasm.
use glowcap::{Argument, Locator, PendingWork, Runtime, RuntimeConfig, Session};
use rooms_application::archive::{
	index::{Index, Page},
	shares, Access, Body, ConversationKind, Coordinates, Facet, Filter, LineState, Record,
};
use rooms_browser::platform::Platform;
use rooms_glowcap::client::{archive::Archive as ClientArchive, Client};
use rooms_runtime::{
	archive::{Archive, Backend},
	session_archive::SessionArchive,
};
use std::rc::Rc;

pub(super) struct Memory {
	index: Index,
	shares: shares::Ledger,
}
impl Memory {
	pub(super) fn new() -> Self {
		Self {
			index: Index::new(32).unwrap(),
			shares: Default::default(),
		}
	}
}
impl Backend for Memory {
	async fn put(&mut self, record: Record) -> Result<u64, String> {
		let revision = self.index.revision() + 1;
		self.index.apply(revision, record).map_err(|e| e.to_string())?;
		Ok(revision)
	}
	async fn read(&mut self, filter: &Filter, after: u64, limit: usize) -> Result<Page, String> {
		self.index.read(filter, after, limit).map_err(|e| e.to_string())
	}
	async fn clear(&mut self) -> Result<(), String> {
		self.index.clear();
		Ok(())
	}
	fn durable_shares(&self) -> bool {
		true
	}
	async fn active_shares(&mut self) -> Result<Vec<shares::Share>, String> {
		Ok(self
			.shares
			.records()
			.map_err(|e| e.to_string())?
			.filter(|s| !s.revoked())
			.cloned()
			.collect())
	}
	async fn change_share(&mut self, command: shares::Command) -> Result<shares::Change, String> {
		self.shares
			.apply::<String>(command, |_| Ok(()))
			.map_err(|e| format!("{e:?}"))
	}
}
fn record() -> Record {
	Record::new(
		Coordinates {
			source: "wasm".into(),
			generation: "one".into(),
			id: "line".into(),
		},
		"directory".into(),
		Body::Line {
			conversation_kind: ConversationKind::Room,
			conversation: "garden".into(),
			from: "browser".into(),
			text: "kept by the shared worker".into(),
			mine: false,
			at: 1,
			order: 1,
			state: LineState::Present,
			attachments: vec![],
		},
	)
	.unwrap()
}
async fn offered(
	session: &Session,
	client: &Client<Platform>,
	name: &str,
	reference: glowcap::Ref,
) -> ClientArchive<Platform> {
	let publication = session.publish(name, move |_, _| Ok(reference.clone().into())).unwrap();
	let root = client.session().fetch(name).await.unwrap();
	let Argument::Reference(reference) = client.session().send(&root, "root", &[]).await.unwrap() else {
		panic!("archive reference")
	};
	session.release(publication).unwrap();
	ClientArchive::new(client.clone(), reference)
}
pub async fn exercise(client: &Client<Platform>, accepted: &Session, locator: &Locator) {
	let platform = client.platform().clone();
	exercise_backend(client, accepted, Memory::new()).await;
	if js_sys::Reflect::has(&js_sys::global(), &"indexedDB".into()).unwrap() {
		let database = rooms_browser::storage::Database::open().await.unwrap();
		exercise_backend(client, accepted, rooms_browser::storage::Archive::new(database.clone())).await;
		database.close().await;
	}

	let runtime = Rc::new(Runtime::open(RuntimeConfig::connectors([])).await.unwrap());
	let (owner, worker) = SessionArchive::new(platform.clone(), runtime.clone(), Memory::new());
	let task = tokio::task::spawn_local(worker.with_issuer(accepted.host(), locator.clone(), [61; 16]).run());
	owner.put(record(), vec![]).unwrap().wait().await.unwrap();
	let reference = owner
		.share(
			accepted.borrowed(),
			Facet::new(Filter::default(), Access::Read).unwrap(),
		)
		.unwrap()
		.wait()
		.await
		.unwrap();
	let live = offered(accepted, client, "wasm-session-archive", reference).await;
	let spec = shares::Share::new(
		"12345678-1234-4234-8234-123456789abc".into(),
		"kept".into(),
		Filter::default(),
	)
	.unwrap();
	let link = owner.issue_share(spec.clone()).unwrap().wait().await.unwrap();
	let durable_ref = client.session().enliven(&link).await.unwrap();
	let durable = ClientArchive::new(client.clone(), durable_ref.clone());
	let child = durable.narrow(&Filter::default(), Access::Read).await.unwrap();
	assert_eq!(child.read_all(&Filter::default()).await.unwrap().len(), 1);
	assert!(client
		.session()
		.send(&durable_ref, "read", &[const { Argument::Void }; 4])
		.await
		.is_err());
	// Failed selection cannot reinterpret a previously granted local archive.
	assert!(owner
		.select(Some("ocapn://missing.invalid?transport=tcp".into()))
		.unwrap()
		.wait()
		.await
		.is_err());
	assert!(owner.read(Filter::default()).unwrap().wait().await.is_err());
	assert_eq!(live.read_all(&Filter::default()).await.unwrap().len(), 1);
	assert_eq!(child.read_all(&Filter::default()).await.unwrap().len(), 1);
	owner.select(None).unwrap().wait().await.unwrap();
	assert!(owner.revoke_share(spec.id().into()).unwrap().wait().await.unwrap());
	assert!(durable.read_all(&Filter::default()).await.is_err());
	assert!(child.read_all(&Filter::default()).await.is_err());
	// Narrowing and releasing still spends this caller's lifetime mint budget.
	for _ in 1..rooms_application::archive::request::MAX_FACETS_PER_SESSION {
		drop(live.narrow(&Filter::default(), Access::Read).await.unwrap());
	}
	assert!(live.narrow(&Filter::default(), Access::Read).await.is_err());

	let unrevoked = shares::Share::new(
		"87654321-1234-4234-8234-123456789abc".into(),
		"retire with owner".into(),
		Filter::default(),
	)
	.unwrap();
	let retired_link = owner.issue_share(unrevoked.clone()).unwrap().wait().await.unwrap();
	let report = owner.close().await.unwrap();
	assert_eq!(report.lost_replies, 0);
	assert_eq!(report.cleanup_failures, 0);
	assert_eq!(task.await.unwrap(), report);
	assert!(live.read_all(&Filter::default()).await.is_err());
	drop((live, durable, durable_ref, child, owner));

	// Closing releases owned lookup names while keeping the shared Host alive.
	let (replacement, worker) = SessionArchive::new(platform, runtime.clone(), Memory::new());
	let task = tokio::task::spawn_local(worker.with_issuer(accepted.host(), locator.clone(), [61; 16]).run());
	assert_eq!(
		replacement.issue_share(unrevoked).unwrap().wait().await.unwrap(),
		retired_link
	);
	let renewed = ClientArchive::new(client.clone(), client.session().enliven(&retired_link).await.unwrap());
	assert!(renewed.read_all(&Filter::default()).await.unwrap().is_empty());
	replacement.close().await.unwrap();
	task.await.unwrap();
	drop((renewed, replacement));
	runtime.close(PendingWork::Cancel).await.unwrap();
}

async fn exercise_backend<B: Backend + 'static>(client: &Client<Platform>, accepted: &Session, backend: B) {
	let platform = client.platform().clone();
	let (archive, worker) = Archive::new(platform, backend);
	let hosted = offered(
		accepted,
		client,
		"wasm-archive",
		archive
			.receiver()
			.spawn(accepted, Facet::new(Filter::default(), Access::ReadWrite).unwrap())
			.unwrap(),
	)
	.await;
	let task = tokio::task::spawn_local(worker.run());
	hosted.put(&record()).await.unwrap();
	assert_eq!(hosted.read_all(&Filter::default()).await.unwrap().len(), 1);
	archive.clear().await.unwrap();
	assert!(hosted.read_all(&Filter::default()).await.unwrap().is_empty());
	archive.close().await.unwrap();
	task.await.unwrap();
	drop(hosted);
}
