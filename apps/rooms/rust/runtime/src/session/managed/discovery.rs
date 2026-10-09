//! Discovery owns one exact upstream observer through admission and retirement.
//! Public readers never receive WATCH or raw cancellation authority.
use super::{Membership, Session, inbox, supervision};
use glowcap::{Argument, Result, loam};
use rooms_application::{
	content::{
		permissions::Permission,
		session::{custody, workspace},
	},
	directory,
};
use rooms_glowcap::client::{Deadline, Tasks};
use std::{
	future::{Future, IntoFuture},
	pin::Pin,
};
use tokio::sync::{oneshot, watch};

mod pending;
type Pending = Pin<Box<dyn Future<Output = Result<Argument>>>>;
const WAIT_MS: u64 = 20_000;

pub struct DirectoryWatch<P: Tasks> {
	lifetime: Membership<P>,
	snapshot: Option<oneshot::Receiver<Result<directory::Snapshot>>>,
	synchronized: watch::Sender<bool>,
	origin: super::InboxOrigin,
}
impl<P: Tasks> DirectoryWatch<P> {
	pub fn status(&self) -> Option<Result<()>> {
		self.lifetime.status()
	}
	pub fn origin(&self) -> &super::InboxOrigin {
		&self.origin
	}
	/// Call only after the initial snapshot has been accepted. Queued changes
	/// then recheck their exact source before delivery.
	pub fn accept_snapshot(&self) {
		self.synchronized.send_replace(true);
	}
	pub async fn snapshot(&mut self) -> Result<directory::Snapshot> {
		let receiver = self
			.snapshot
			.as_mut()
			.ok_or_else(|| loam::refusal("directory snapshot was already taken"))?;
		let result = receiver.await;
		self.snapshot = None;
		result.map_err(|_| loam::refusal("directory discovery lost its startup outcome"))?
	}
	pub fn is_active(&self) -> bool {
		self.lifetime.is_active()
	}
	pub fn retry(&self) {
		if !self.lifetime.retry_retirement() {
			self.lifetime.retry();
		}
	}
	pub async fn close(&mut self) -> Result<()> {
		self.lifetime.close().await
	}
}
impl<P: Tasks + Deadline + Clone + 'static> Session<P> {
	/// ObserveWorkspace through the row's original source suffices. Discovery
	/// installs no member or nickname. Cleanup privately retains the original
	/// target so source retirement cannot strand its exact cancellation.
	pub async fn watch_directory(
		&self,
		row: &workspace::Directory,
		mut receive: impl FnMut(directory::Event, &super::InboxOrigin) -> core::result::Result<(), String> + 'static,
	) -> Result<DirectoryWatch<P>> {
		let _permit = supervision::Permit::reserve(&self.state.discovery_observers)?;
		let selected = workspace::DiscoverySelection::directory(row)
			.ok_or_else(|| loam::refusal("directory discovery has no initiating source"))?;
		let source = self.directory_source(row).await?;
		let workspace = source.workspace().clone();
		workspace.check_discovery(&selected).await.map_err(error)?;
		let coordinate = custody::Coordinate {
			role: custody::Role::DirectoryAccess,
			key: custody::FieldKey::new(selected.access.slot(), selected.access.generation()),
		};
		let target = self.restore_custody(&[coordinate]).await?.remove(0);
		let connection = supervision::retirement::exporter(&self.state.writer.host, &target)?;
		workspace.check_discovery(&selected).await.map_err(error)?;
		// No await separates the closing/identity checks from inbox and task
		// insertion. The startup permit remains charged throughout restoration.
		if self.state.closing.get() {
			return Err(loam::refusal("session is closing"));
		}
		let id = format!(
			"discovery-{}",
			selected
				.id
				.text()
				.as_str()
				.ok_or_else(|| loam::refusal("invalid discovery ID"))?
		);
		let budget = &self.state.discovery_observers;
		if budget.contains(&id) || budget.contains_target(&target) {
			return Err(loam::refusal("directory discovery already has a live owner"));
		}
		let changes = self.state.changes.subscribe(&self.state)?;
		let (synchronized, synchronizing) = watch::channel(false);
		let inbox = inbox::open_discovery(
			&self.state.writer.host,
			self.state.platform.clone(),
			workspace.clone(),
			selected.clone(),
			self.state.inboxes.clone(),
			synchronizing,
			move |args, origin| {
				let event = directory::event_fields(args.len(), |index| args.get(index).map(rooms_glowcap::Value))
					.ok_or("invalid directory discovery notification")?;
				receive(event, origin)
			},
		)?;
		let observer = inbox.reference().clone();
		let origin = inbox.origin().clone();
		let platform = self.state.platform.clone();
		let writer = self.state.writer.clone();
		let recovery = self.state.discovery_refresh.clone();
		let identity = target.clone();
		let (snapshot, receiving) = oneshot::channel();
		let lifetime = supervision::spawn(&platform.clone(), budget, id.clone(), None, move |signals| async move {
			let mut worker = Worker {
				inbox,
				target,
				connection,
				recovery,
				observer,
				platform,
				writer,
				workspace,
				selected,
				changes,
				signals,
			};
			worker.run(snapshot).await
		});
		budget.identify(&id, identity);
		Ok(DirectoryWatch {
			lifetime,
			snapshot: Some(receiving),
			synchronized,
			origin,
		})
	}
}
fn error(failure: impl core::fmt::Display) -> glowcap::Error {
	loam::refusal(failure.to_string())
}

struct Worker<P: Tasks> {
	inbox: inbox::Inbox<P>,
	target: glowcap::Ref,
	connection: Option<glowcap::Session>,
	recovery: std::rc::Rc<super::watching::Refresh>,
	observer: glowcap::Ref,
	platform: P,
	writer: std::rc::Rc<super::executor::Writer>,
	workspace: rooms_glowcap::client::workspace::Workspace<P>,
	selected: workspace::DiscoverySelection,
	changes: super::changes::Wake,
	signals: supervision::Signals,
}
impl<P: Tasks + Deadline + Clone + 'static> Worker<P> {
	async fn run(&mut self, snapshot: oneshot::Sender<Result<directory::Snapshot>>) -> Result<()> {
		if *self.signals.stopping.borrow() {
			let _ = snapshot.send(Err(loam::refusal("directory discovery closed before admission")));
			return self.inbox.close().await;
		}
		// Dispatch once and continue observing the original receiver after a
		// deadline or dropped view. Unknown WATCH never creates another observer.
		let mut admission: Pending = Box::pin(
			self.writer
				.host
				.send(&self.target, directory::WATCH, &[self.observer.clone().into()])
				.into_future(),
		);
		let result = match pending::wait(&self.platform, &mut admission, &mut self.signals, false).await {
			Ok(reply) => match self.workspace.check_discovery(&self.selected).await {
				Ok(()) => directory::snapshot(&rooms_glowcap::Value(&reply)).map_err(error),
				Err(failure) => Err(error(failure)),
			},
			Err(failure) => Err(failure),
		};
		self.signals
			.ready
			.send_replace(Some(result.as_ref().map(|_| ()).map_err(Clone::clone)));
		let _ = snapshot.send(result);
		self.monitor().await;
		// Drain even when a callback's resolver failed. A drained failure remains
		// visible but cannot prevent exact upstream cancellation.
		let closed = self.inbox.close().await;
		if !self.inbox.drained() {
			return closed;
		}
		// Directory observers are also leases of the accepted connection.
		// Its end withdraws WATCH; there is no live endpoint left to UNWATCH.
		if self.connection.as_ref().is_some_and(|connection| !connection.is_open()) {
			return closed;
		}
		loop {
			let mut cancellation: Pending = Box::pin(
				self.writer
					.host
					.send(&self.target, directory::UNWATCH, &[self.observer.clone().into()])
					.into_future(),
			);
			let outcome = pending::wait(&self.platform, &mut cancellation, &mut self.signals, true).await;
			let failure = match outcome {
				Ok(Argument::Void) => return closed,
				Ok(_) => loam::refusal("invalid directory cancellation acknowledgment"),
				Err(failure) => failure,
			};
			self.signals
				.finished
				.send_replace(Some(Err(failure.with_cleanup(closed.clone()))));
			// Only a confirmed refusal permits a fresh exact UNWATCH. An unknown
			// receiver remains inside pending::wait and is continuously observed.
			tokio::select! {
				_ = self.signals.stopping.changed() => {},
				_ = self.signals.retrying.changed() => {},
			}
		}
	}
	async fn monitor(&mut self) {
		while !*self.signals.stopping.borrow_and_update() {
			let changed = tokio::select! {
				biased;
				_ = self.signals.stopping.changed() => return,
				_ = async {
					match &self.connection {
						Some(connection) => { let _terminal = connection.ended().await; },
						None => std::future::pending().await,
					}
				} => { self.recovery.recover(); return; },
				_ = self.signals.retrying.changed() => { self.changes.retry(); continue; },
				changed = self.changes.changed() => changed,
			};
			let current = match changed {
				Ok(()) => self
					.platform
					.within(WAIT_MS, self.current())
					.await
					.unwrap_or_else(|| Err(loam::refusal("discovery source check is still unresolved"))),
				Err(failure) => Err(failure),
			};
			match current {
				Ok(false) => return,
				Ok(true) => {}
				Err(failure) => {
					self.writer.report("Directory discovery", &failure);
					self.signals.ready.send_replace(Some(Err(failure)));
					tokio::select! {
						_ = self.signals.stopping.changed() => return,
						_ = self.signals.retrying.changed() => self.changes.retry(),
					}
				}
			}
		}
	}
	async fn current(&self) -> Result<bool> {
		let selected =
			serde_json::to_string(&self.selected).map_err(|_| loam::refusal("invalid discovery selection"))?;
		match self.writer.idempotent("discovery-selected", &[selected.into()]).await? {
			Argument::Boolean(false) => return Ok(false),
			Argument::Boolean(true) => {}
			_ => return Err(loam::refusal("invalid discovery selection acknowledgment")),
		}
		let description = self
			.writer
			.idempotent_through(self.workspace.reference(), "describe-access", &[])
			.await?;
		Ok(match loam::UseDescription::read(&description)? {
			loam::UseDescription::Revoked | loam::UseDescription::OutOfScope => false,
			loam::UseDescription::Paused => true,
			loam::UseDescription::Active(source) => source
				.effective
				.permissions()
				.any(|permission| permission == Permission::ObserveWorkspace.key()),
		})
	}
}
