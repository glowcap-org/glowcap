use super::*;
use crate::archive::Archive;
use glowcap::{Host, ListenerIdentity, PendingWork, RuntimeConfig, tcp};
use rooms_application::archive::{Body, ConversationKind, Coordinates, LineState, index::Index};
use rooms_runtime::Error;
use std::{cell::RefCell, time::Duration};
use tokio::sync::Notify;
#[path = "admission_tests.rs"]
mod admission_tests;
mod recording_tests;
pub(super) struct Memory {
	index: Rc<RefCell<Index>>,
	blocked: Rc<Cell<bool>>,
	erase_fails: Rc<Cell<bool>>,
	put_fails: Rc<Cell<Option<rooms_application::archive::Kind>>>,
	attempts: Rc<RefCell<Vec<rooms_application::archive::Kind>>>,
	gate: Rc<Notify>,
	started: Rc<Notify>,
}
impl Memory {
	pub(super) fn new() -> Self {
		Self {
			index: Rc::new(RefCell::new(Index::new(5000).unwrap())),
			blocked: Rc::new(Cell::new(false)),
			erase_fails: Rc::new(Cell::new(false)),
			put_fails: Rc::new(Cell::new(None)),
			attempts: Rc::new(RefCell::new(Vec::new())),
			gate: Rc::new(Notify::new()),
			started: Rc::new(Notify::new()),
		}
	}
}
impl Backend for Memory {
	fn durable_shares(&self) -> bool {
		true
	}
	async fn active_shares(&mut self) -> Result<Vec<rooms_application::archive::shares::Share>, Error> {
		Ok(Vec::new())
	}
	async fn clear(&mut self) -> Result<(), Error> {
		if self.erase_fails.get() {
			return Err(Error::storage_message("forced erase refusal"));
		}
		self.index.borrow_mut().clear();
		Ok(())
	}
	async fn put(&mut self, record: Record) -> Result<u64, Error> {
		self.attempts.borrow_mut().push(record.kind());
		self.started.notify_one();
		if self.blocked.get() {
			self.gate.notified().await;
		}
		if self.put_fails.get() == Some(record.kind()) {
			return Err(Error::storage_message("forced write refusal"));
		}
		let mut index = self.index.borrow_mut();
		let revision = index.revision() + 1;
		index.apply(revision, record).map_err(Error::archive)?;
		Ok(revision)
	}
	async fn read(&mut self, filter: &Filter, after: u64, limit: usize) -> Result<Page, Error> {
		self.index.borrow().read(filter, after, limit).map_err(Error::archive)
	}
}
fn line(state: LineState) -> Record {
	Record::new(
		Coordinates {
			source: "source".into(),
			generation: "generation".into(),
			id: "line".into(),
		},
		"directory".into(),
		Body::Line {
			conversation_kind: ConversationKind::Room,
			conversation: "garden".into(),
			from: "alice".into(),
			text: if state == LineState::Withdrawn { "" } else { "kept" }.into(),
			mine: false,
			at: 1,
			order: 1,
			state,
			previews: Default::default(),
			attachments: vec![],
		},
	)
	.unwrap()
}
async fn runtime() -> Rc<Runtime> {
	Rc::new(
		Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
			.await
			.unwrap(),
	)
}
#[tokio::test]
async fn ordered_selection_merge_erasure_and_source_retirement() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(20), scenario())
				.await
				.expect("session archive deadline");
		})
		.await;
}
async fn scenario() {
	let runtime = runtime().await;
	let host = Host::from_seed([210; 32]).unwrap();
	let listener = Rc::new(
		tcp::listen(
			"127.0.0.1",
			0,
			tcp::ListenOptions {
				identity: ListenerIdentity::Host(host.clone()),
				..Default::default()
			},
		)
		.await
		.unwrap(),
	);
	let (remote_owner, mut remote_worker) = Archive::new(rooms_platform::HostPlatform, Memory::new());
	let link = remote_worker
		.publish(host.clone(), [42; 16], listener.locator().unwrap())
		.await
		.unwrap();
	let remote_worker = tokio::task::spawn_local(remote_worker.run());
	let active = Rc::new(Cell::new(0usize));
	let service_listener = listener.clone();
	let service_active = active.clone();
	let server = tokio::task::spawn_local(async move {
		let mut sessions = tokio::task::JoinSet::new();
		while let Ok(session) = service_listener.accept().await {
			let count = service_active.clone();
			count.set(count.get() + 1);
			sessions.spawn_local(async move {
				let session = session;
				let _ = session.serve().await;
				session.close(PendingWork::Cancel).await.unwrap();
				count.set(count.get() - 1);
			});
		}
		while let Some(result) = sessions.join_next().await {
			result.unwrap();
		}
	});
	let local = Memory::new();
	let local_index = local.index.clone();
	let blocked = local.blocked.clone();
	let gate = local.gate.clone();
	let started = local.started.clone();
	let erase_fails = local.erase_fails.clone();
	blocked.set(true);
	let (owner, worker) = SessionArchive::new(rooms_platform::HostPlatform, runtime.clone(), local);
	let worker = tokio::task::spawn_local(worker.run());
	drop(owner.put(line(LineState::Present), vec![]).unwrap());
	started.notified().await;
	let prepared = owner.prepare(link.clone()).unwrap();
	let selected = owner.select(Some(link.clone())).unwrap();
	let edited = owner.put(line(LineState::Edited), vec![]).unwrap();
	assert_eq!(active.get(), 0, "selection overtook the earlier write");
	blocked.set(false);
	gate.notify_one();
	prepared.wait().await.unwrap();
	selected.wait().await.unwrap();
	edited.wait().await.unwrap();
	assert!(owner.prepare("invalid archive".into()).unwrap().wait().await.is_err());
	assert_eq!(local_index.borrow().revision(), 1, "remote write fell back locally");
	let kept = owner.read(Filter::default()).unwrap().wait().await.unwrap();
	assert_eq!(kept.len(), 1);
	assert!(matches!(kept[0].keeper, Keeper::Peer(_)));
	assert!(matches!(
		kept[0].record.body(),
		Body::Line {
			state: LineState::Edited,
			..
		}
	));
	owner.select(None).unwrap().wait().await.unwrap();
	owner.prepare(link.clone()).unwrap().wait().await.unwrap();
	owner.select(Some(link.clone())).unwrap().wait().await.unwrap();
	owner.select(None).unwrap().wait().await.unwrap();
	assert_eq!(active.get(), 1, "selection closed the archive supplying a held view");
	owner
		.put(line(LineState::Withdrawn), vec![])
		.unwrap()
		.wait()
		.await
		.unwrap();
	let local_view = owner.read(Filter::default()).unwrap().wait().await.unwrap();
	assert!(matches!(local_view[0].keeper, Keeper::Local(_)));
	drop(kept);
	assert_eq!(
		active.get(),
		1,
		"archive-source retirement condemned the Host's pooled carrier"
	);
	assert!(
		owner
			.select(Some("invalid archive".into()))
			.unwrap()
			.wait()
			.await
			.is_err()
	);
	let revision = local_index.borrow().revision();
	assert!(
		owner
			.put(line(LineState::Present), vec![])
			.unwrap()
			.wait()
			.await
			.is_err()
	);
	assert_eq!(local_index.borrow().revision(), revision);
	owner.select(None).unwrap().wait().await.unwrap();
	erase_fails.set(true);
	assert!(owner.clear_local().unwrap().wait().await.is_err());
	assert!(owner.read(Filter::default()).unwrap().wait().await.is_err());
	assert!(
		owner
			.put(line(LineState::Present), vec![])
			.unwrap()
			.wait()
			.await
			.is_err()
	);
	assert_eq!(local_index.borrow().revision(), revision);
	erase_fails.set(false);
	assert!(owner.read(Filter::default()).unwrap().wait().await.unwrap().is_empty());
	assert_eq!(local_index.borrow().revision(), revision);
	owner.select(Some(link.clone())).unwrap().wait().await.unwrap();
	let remote = recording_tests::admit(&owner, "garden", ConversationKind::Room, 1);
	assert!(remote.completion.wait().await.unwrap().standing.unwrap().is_some());
	owner.select(None).unwrap().wait().await.unwrap();
	let local = recording_tests::admit(&owner, "garden", ConversationKind::Room, 1);
	assert!(local.completion.wait().await.unwrap().standing.unwrap().is_some());
	owner.select(Some(link.clone())).unwrap().wait().await.unwrap();
	let held_at_close = owner.read(Filter::default()).unwrap().wait().await.unwrap();
	assert!(matches!(held_at_close[0].keeper, Keeper::Peer(_)));
	let report = owner.close().await.unwrap();
	assert_eq!(
		active.get(),
		1,
		"archive shutdown condemned the enclosing Runtime's pooled carrier"
	);
	if let Keeper::Peer(peer) = &held_at_close[0].keeper {
		assert!(peer.blob(&"ab".repeat(32)).await.is_err());
	}
	assert_eq!(report.lost_replies, 1);
	assert_eq!(report.cleanup_failures, 0);
	assert!(owner.put(line(LineState::Present), vec![]).is_err());
	assert_eq!(worker.await.unwrap(), report);
	// The supplied runtime still owns and can reuse the carrier after this
	// archive source released its own capability and application handle.
	let reference = runtime
		.host()
		.enliven_for_version(&link, glowcap::CaptpVersion::V1_0)
		.await
		.unwrap();
	let session = runtime.host().reference_session(&reference).unwrap().unwrap();
	assert!(session.is_open());
	drop(reference);
	session.relinquish(PendingWork::Cancel).await.unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
	listener.close().await.unwrap();
	remote_owner.close().await.unwrap();
	remote_worker.await.unwrap();
	host.close(PendingWork::Cancel).await.unwrap();
	server.await.unwrap();
}
#[tokio::test]
async fn admission_counts_abandoned_observations_and_close_drains_the_queue() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let runtime = runtime().await;
			let (owner, worker) = SessionArchive::new(rooms_platform::HostPlatform, runtime.clone(), Memory::new());
			let mut replies = Vec::new();
			for _ in 0..MAX_PENDING {
				replies.push(owner.put(line(LineState::Present), vec![]).unwrap());
			}
			drop(replies.pop());
			assert!(owner.put(line(LineState::Present), vec![]).is_err());
			let mut closing = Box::pin(owner.close());
			assert!(
				core::future::Future::poll(
					closing.as_mut(),
					&mut std::task::Context::from_waker(std::task::Waker::noop())
				)
				.is_pending()
			);
			let worker = tokio::task::spawn_local(worker.run());
			for reply in replies {
				reply.wait().await.unwrap();
			}
			let report = owner.close().await.unwrap();
			assert_eq!(report.completed, MAX_PENDING as u64);
			assert_eq!(report.lost_replies, 1);
			assert_eq!(worker.await.unwrap(), report);
			runtime.close(PendingWork::Cancel).await.unwrap();
		})
		.await;
}
