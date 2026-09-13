use super::RetentionEvents;
use crate::{session_archive::SessionArchive, session_commands::SessionEvents, session_state::SessionView};
use rooms_application::session::{
	checkpoint::{commands::Facts, reconciliation::Fact},
	state::Change,
};
use std::rc::Rc;
fn keeps_history(view: &SessionView) -> Result<bool, Error> {
	Ok(view.read(|state| state.checkpoint().map(|checkpoint| checkpoint.keeps_history()))??)
}
use crate::{
	archive::{
		Backend,
		file::{FileArchive, Options},
	},
	documents::SessionDocuments,
	session_commands::{Reply, SessionCommands},
};
use glowcap::{PendingWork, Runtime, RuntimeConfig};
use rooms_application::{
	archive::{
		Body, ConversationKind, Coordinates, Filter, LineState, Record,
		index::{Index, Page},
	},
	session::{checkpoint::commands::Command, state::OperationId},
};
use rooms_runtime::Error;
use std::{
	cell::{Cell, RefCell},
	path::PathBuf,
	time::Duration,
};
use tokio::sync::Notify;

struct Events;
impl SessionEvents for Events {
	async fn preparing(
		&mut self,
		_checkpoint: &rooms_application::session::checkpoint::Checkpoint,
	) -> Result<impl Sized + 'static, Error> {
		Ok(())
	}

	fn facts(&self) -> impl Facts {}
	fn changed(&mut self, _: Change, _: &SessionView) {}
	fn reconciliation_issue(&mut self, _: &Fact, _: Option<&str>) {}
}
struct Temp(PathBuf);
impl Temp {
	fn new(label: &str) -> Self {
		let path = std::env::temp_dir().join(format!("rooms-retention-{label}-{}", std::process::id()));
		std::fs::create_dir(&path).unwrap();
		Self(path)
	}
}
impl Drop for Temp {
	fn drop(&mut self) {
		std::fs::remove_dir_all(&self.0).unwrap();
	}
}
async fn session(path: &std::path::Path) -> crate::session_state::DurableSession {
	let owners = SessionDocuments::open(path).await.unwrap().into_owners();
	drop((owners.grants, owners.bridge_secrets));
	owners.state
}
fn retention(commands: &SessionCommands, id: &str, base: u64, keep: bool) -> Reply<u64> {
	commands
		.prepare_command(
			OperationId::new(id.into()).unwrap(),
			base,
			Command::ChooseHistoryRetention,
			vec![keep.to_string().into()],
		)
		.unwrap()
		.send()
		.unwrap()
}
fn record(id: usize) -> Record {
	Record::new(
		Coordinates {
			source: "session".into(),
			generation: "generation".into(),
			id: id.to_string().into(),
		},
		"directory".into(),
		Body::Line {
			conversation_kind: ConversationKind::Direct,
			conversation: "conversation".into(),
			from: "alice".into(),
			text: "retained".into(),
			mine: false,
			at: 1,
			order: 1,
			state: LineState::Present,
			previews: Default::default(),
			attachments: vec![],
		},
	)
	.unwrap()
}
struct Memory {
	index: Rc<RefCell<Index>>,
	fail: Rc<Cell<bool>>,
	block: Rc<Cell<bool>>,
	entered: Rc<Notify>,
	release: Rc<Notify>,
	clears: Rc<Cell<usize>>,
}
impl Backend for Memory {
	async fn clear(&mut self) -> Result<(), Error> {
		self.entered.notify_one();
		if self.block.get() {
			self.release.notified().await;
		}
		if self.fail.get() {
			return Err(Error::storage_message("forced erasure failure"));
		}
		self.index.borrow_mut().clear();
		self.clears.set(self.clears.get() + 1);
		Ok(())
	}
	async fn put(&mut self, record: Record) -> Result<u64, Error> {
		let mut index = self.index.borrow_mut();
		let revision = index.revision() + 1;
		index.apply(revision, record).unwrap();
		Ok(revision)
	}
	async fn read(&mut self, filter: &Filter, after: u64, limit: usize) -> Result<Page, Error> {
		self.index.borrow().read(filter, after, limit).map_err(Error::archive)
	}
}
async fn local(work: impl std::future::Future<Output = ()>) {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(20), work).await.unwrap();
		})
		.await;
}
#[tokio::test]
async fn retention_waits_for_archive_capacity_and_fences_reenable_until_erasure() {
	local(async {
		let temp = Temp::new("pressure");
		let (commands, worker) = SessionCommands::open(session(&temp.0).await, rooms_platform::HostPlatform)
			.await
			.unwrap();
		let runtime = Rc::new(Runtime::open(RuntimeConfig::providers([])).await.unwrap());
		let block = Rc::new(Cell::new(true));
		let fail = Rc::new(Cell::new(false));
		let entered = Rc::new(Notify::new());
		let release = Rc::new(Notify::new());
		let clears = Rc::new(Cell::new(0));
		let (archive, archive_worker) = SessionArchive::new(
			rooms_platform::HostPlatform,
			runtime.clone(),
			Memory {
				index: Rc::new(RefCell::new(Index::new(5000).unwrap())),
				block: block.clone(),
				fail: fail.clone(),
				entered: entered.clone(),
				release: release.clone(),
				clears: clears.clone(),
			},
		);
		let archive = Rc::new(archive);
		let (directories, directory_worker, events, _inbox) = crate::session_retention::directories(
			runtime.clone(),
			commands.clone(),
			"ocapn://member.id".into(),
			archive.clone(),
		)
		.await
		.unwrap();
		let directory_task = tokio::task::spawn_local(directory_worker.run());
		let task = tokio::task::spawn_local(worker.run(events));
		let mut queued = Vec::new();
		for id in 0..64 {
			queued.push(archive.put(record(id), Vec::new()).unwrap());
		}
		assert!(archive.clear_local().is_err(), "normal queue is saturated");
		let mut disabled = Box::pin(retention(&commands, "disable", 0, false).wait());
		let mut enabled = Box::pin(retention(&commands, "enable", 1, true).wait());
		assert!(
			tokio::time::timeout(Duration::from_millis(10), &mut disabled)
				.await
				.is_err()
		);
		let archive_task = tokio::task::spawn_local(archive_worker.run());
		entered.notified().await;
		for reply in queued {
			reply.wait().await.unwrap();
		}
		assert!(keeps_history(&commands.view()).unwrap());
		assert!(
			tokio::time::timeout(Duration::from_millis(10), &mut enabled)
				.await
				.is_err()
		);
		block.set(false);
		release.notify_one();
		assert_eq!(disabled.await.unwrap(), 1);
		assert_eq!(enabled.await.unwrap(), 2);
		assert_eq!(clears.get(), 1);
		assert!(
			archive
				.read(Filter::default())
				.unwrap()
				.wait()
				.await
				.unwrap()
				.is_empty()
		);
		archive.put(record(100), Vec::new()).unwrap().wait().await.unwrap();
		// A failed erase preserves the prior checkpoint and operation revision.
		// Retrying the same operation can commit only after erasure succeeds.
		fail.set(true);
		assert!(
			retention(&commands, "disable-again", 2, false)
				.wait()
				.await
				.unwrap_err()
				.to_string()
				.contains("forced erasure")
		);
		assert!(retention(&commands, "enable-again", 3, true).wait().await.is_err());
		assert!(keeps_history(&commands.view()).unwrap());
		assert_eq!(commands.view().read(|state| state.revision()).unwrap().unwrap(), 2);
		fail.set(false);
		assert_eq!(retention(&commands, "disable-again", 2, false).wait().await.unwrap(), 3);
		assert_eq!(retention(&commands, "enable-again", 3, true).wait().await.unwrap(), 4);
		assert_eq!(clears.get(), 2);
		assert!(
			archive
				.read(Filter::default())
				.unwrap()
				.wait()
				.await
				.unwrap()
				.is_empty()
		);
		directories.close().await.unwrap();
		directory_task.await.unwrap().unwrap();
		commands.close().await.unwrap();
		task.await.unwrap().unwrap();
		archive.close().await.unwrap();
		archive_task.await.unwrap();
		runtime.close(PendingWork::Cancel).await.unwrap();
	})
	.await;
}

#[tokio::test]
async fn restored_disabled_checkpoint_erases_before_readiness_and_reenabled_history_survives_restart() {
	local(async {
		let temp = Temp::new("restore");
		let path = temp.0.join("archive");
		let runtime = Rc::new(Runtime::open(RuntimeConfig::providers([])).await.unwrap());
		let mut disk = FileArchive::open(&path, Options::default()).await.unwrap();
		disk.put(record(1)).await.unwrap();
		drop(disk);
		let mut state = session(&temp.0).await;
		assert!(matches!(
			state.load().await.unwrap(),
			crate::session_state::LoadStatus::Ready
		));
		// Simulate interruption after checkpoint commitment, before its observer
		// could run. This bypass is a recovery fixture, not a production command.
		state
			.command(
				OperationId::new("disable".into()).unwrap(),
				0,
				Command::ChooseHistoryRetention,
				&["false".into()],
				&(),
			)
			.await
			.unwrap();
		drop(state);
		for restored_keep in [false, true] {
			let (commands, worker) = SessionCommands::open(session(&temp.0).await, rooms_platform::HostPlatform)
				.await
				.unwrap();
			assert_eq!(keeps_history(&commands.view()).unwrap(), restored_keep);
			let (archive, archive_worker) = SessionArchive::new(
				rooms_platform::HostPlatform,
				runtime.clone(),
				FileArchive::open(&path, Options::default()).await.unwrap(),
			);
			let archive = Rc::new(archive);
			let archive_task = tokio::task::spawn_local(archive_worker.run());
			let events = RetentionEvents::open(Events, archive.clone(), &commands.view())
				.await
				.unwrap();
			let rows = archive.read(Filter::default()).unwrap().wait().await.unwrap();
			assert_eq!(rows.len(), usize::from(restored_keep));
			if restored_keep {
				assert_eq!(rows[0].record.coordinates().id.as_str(), Some("2"));
			}
			drop(rows);
			let task = tokio::task::spawn_local(worker.run(events));
			if !restored_keep {
				retention(&commands, "enable", 1, true).wait().await.unwrap();
				archive.put(record(2), Vec::new()).unwrap().wait().await.unwrap();
			}
			commands.close().await.unwrap();
			task.await.unwrap().unwrap();
			archive.close().await.unwrap();
			archive_task.await.unwrap();
			drop(archive);
		}
		runtime.close(PendingWork::Cancel).await.unwrap();
	})
	.await;
}

#[tokio::test]
async fn abandoned_command_and_interrupted_worker_cannot_commit_queued_reenable() {
	local(async {
		let temp = Temp::new("interrupt");
		let runtime = Rc::new(Runtime::open(RuntimeConfig::providers([])).await.unwrap());
		let entered = Rc::new(Notify::new());
		let release = Rc::new(Notify::new());
		let block = Rc::new(Cell::new(true));
		let clears = Rc::new(Cell::new(0));
		let (archive, archive_worker) = SessionArchive::new(
			rooms_platform::HostPlatform,
			runtime.clone(),
			Memory {
				index: Rc::new(RefCell::new(Index::new(5000).unwrap())),
				fail: Rc::new(Cell::new(false)),
				block: block.clone(),
				entered: entered.clone(),
				release: release.clone(),
				clears: clears.clone(),
			},
		);
		let archive = Rc::new(archive);
		let archive_task = tokio::task::spawn_local(archive_worker.run());
		archive.put(record(1), Vec::new()).unwrap().wait().await.unwrap();
		let (commands, worker) = SessionCommands::open(session(&temp.0).await, rooms_platform::HostPlatform)
			.await
			.unwrap();
		let events = RetentionEvents::open(Events, archive.clone(), &commands.view())
			.await
			.unwrap();
		let task = tokio::task::spawn_local(worker.run(events));
		drop(retention(&commands, "disable", 0, false));
		entered.notified().await;
		assert!(keeps_history(&commands.view()).unwrap());
		let enabled = retention(&commands, "enable", 1, true);
		task.abort();
		assert!(task.await.unwrap_err().is_cancelled());
		assert!(enabled.wait().await.is_err());
		drop(commands);
		// Archive erasure belongs to its worker after session observation ends.
		block.set(false);
		release.notify_one();
		assert!(
			archive
				.read(Filter::default())
				.unwrap()
				.wait()
				.await
				.unwrap()
				.is_empty()
		);
		assert_eq!(clears.get(), 1);
		let (commands, worker) = SessionCommands::open(session(&temp.0).await, rooms_platform::HostPlatform)
			.await
			.unwrap();
		assert!(
			keeps_history(&commands.view()).unwrap(),
			"interrupted disable never reached durable state"
		);
		let events = RetentionEvents::open(Events, archive.clone(), &commands.view())
			.await
			.unwrap();
		assert_eq!(clears.get(), 1, "uncommitted disable does not erase again at restart");
		let task = tokio::task::spawn_local(worker.run(events));
		retention(&commands, "enable", 0, true).wait().await.unwrap();
		archive.put(record(2), Vec::new()).unwrap().wait().await.unwrap();
		commands.close().await.unwrap();
		task.await.unwrap().unwrap();
		assert_eq!(archive.read(Filter::default()).unwrap().wait().await.unwrap().len(), 1);
		archive.close().await.unwrap();
		archive_task.await.unwrap();
		runtime.close(PendingWork::Cancel).await.unwrap();
	})
	.await;
}
