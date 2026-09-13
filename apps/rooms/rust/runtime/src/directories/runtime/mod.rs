//! Directory supervision, generation custody, and received conversation offers.
//! Platform execution supplies clocks and deadlines; all application ordering
//! and capability lifetimes are shared by native and browser peers.
mod direct;
mod directory_worker;
pub(crate) mod entry;
pub mod handed_rooms;
pub mod room_invitations;
mod state;
#[cfg(test)]
mod tests;
use crate::{Error, clock::Clock, entropy::Entropy};
pub use direct::AcceptedDirect;
use rooms_glowcap::client::{Deadline, Tasks};

/// Execution required by directory supervision and received room capabilities.
pub trait Platform: Clock + Deadline + Tasks + Clone + 'static {}
impl<T: Clock + Deadline + Tasks + Clone + 'static> Platform for T {}

use crate::{
	session::commands::{SessionCommands, SessionEvents},
	session::state::SessionView,
};
pub use directory_worker::DirectoryWorker;
use glowcap::Runtime;
use rooms_application::{
	directory::registration,
	session::{
		checkpoint::{Checkpoint, commands::Facts, reconciliation::Fact},
		state::Change,
	},
	text::DocumentText,
};
use rooms_glowcap::client::directory::Directory;
use state::*;
pub use state::{Directories, DirectoryRow, Phase};
use std::{
	cell::{Ref, RefCell},
	rc::Rc,
};
use tokio::sync::{mpsc, watch};

pub const CONNECTING_LIMIT: usize = 4;
pub const REGISTRATION_LIMIT: usize = 256;
pub const REGISTRATION_BYTES: usize = 2 * 1024 * 1024;

/// An embedding's transport listener follows this exact name-registration
/// generation. It cannot extend or replace the directory owner's authority.
#[derive(Clone)]
pub struct RegisteredDirectory<P: Platform> {
	key: Rc<Generation>,
	directory: Directory<P>,
}
impl<P: Platform> RegisteredDirectory<P> {
	pub fn id(&self) -> &rooms_application::session::checkpoint::reconciliation::Id {
		&self.key.id
	}
	pub fn directory(&self) -> &Directory<P> {
		&self.directory
	}
	pub fn current(&self) -> bool {
		self.key.scope.current()
	}
	pub async fn retired(&self) {
		self.key.scope.retired().await;
	}
	pub fn same_generation(&self, other: &Self) -> bool {
		Rc::ptr_eq(&self.key, &other.key)
	}
}

/// One registration belongs to the exact live directory generation that
/// delivered it. Callers must recheck current() after their own awaited effects.
pub struct RegistrationWork {
	key: Rc<Generation>,
	event: registration::Event,
	_permit: state::NoticePermit,
}
impl RegistrationWork {
	pub fn event(&self) -> &registration::Event {
		&self.event
	}
	pub fn directory(&self) -> &rooms_application::session::checkpoint::reconciliation::Id {
		&self.key.id
	}
	pub fn current(&self) -> bool {
		self.key.scope.current()
	}
}
pub struct RegistrationInbox(mpsc::Receiver<RegistrationWork>);
impl RegistrationInbox {
	/// Refuse further registration work; already admitted notices remain drainable.
	pub fn close(&mut self) {
		self.0.close();
	}
	pub async fn next(&mut self) -> Option<RegistrationWork> {
		while let Some(work) = self.0.recv().await {
			if work.current() {
				return Some(work);
			}
		}
		None
	}
}
#[derive(Clone)]
pub struct DirectoryRuntime<P: Platform> {
	connections: crate::directories::connections::Connections<P>,
	platform: P,
	commands: SessionCommands,
	shared: Rc<RefCell<Directories<P>>>,
	stop: watch::Sender<bool>,
	done: watch::Receiver<Option<Result<(), Error>>>,
	changed: watch::Receiver<()>,
}
type BridgeScope = Rc<RefCell<Option<Box<dyn Fn(&DocumentText) -> Option<DocumentText>>>>>;
pub struct RuntimeEvents<P: Platform> {
	shared: Rc<RefCell<Directories<P>>>,
	checkpoint: watch::Sender<Rc<Checkpoint>>,
	changed: watch::Sender<()>,
	bridge_scope: BridgeScope,
}
impl<P: Platform> DirectoryRuntime<P> {
	/// Construct after SessionCommands::open, then drive both returned workers
	/// on the same local executor. The caller owns transport/listener shutdown.
	pub fn new(
		runtime: Rc<Runtime>,
		commands: SessionCommands,
		member_locator: String,
		platform: P,
		entropy: impl Entropy + 'static,
	) -> Result<(Self, DirectoryWorker<P>, RuntimeEvents<P>, RegistrationInbox), Error> {
		Self::with_connections(
			crate::directories::connections::Connections::new(runtime, platform.clone()),
			commands,
			member_locator,
			platform,
			entropy,
		)
	}
	pub fn with_connections(
		connections: crate::directories::connections::Connections<P>,
		commands: SessionCommands,
		member_locator: String,
		platform: P,
		entropy: impl Entropy + 'static,
	) -> Result<(Self, DirectoryWorker<P>, RuntimeEvents<P>, RegistrationInbox), Error> {
		let initial = commands.view().read(|s| s.checkpoint_handle())??;
		let shared = Rc::new(RefCell::new(Directories::new(
			&initial,
			platform.now(),
			Box::new(entropy),
		)));
		let (checkpoint, latest) = watch::channel(initial);
		let (stop, stopping) = watch::channel(false);
		let (finished, done) = watch::channel(None);
		let (changed, changes) = watch::channel(());
		let (registration, inbox) = mpsc::channel(REGISTRATION_LIMIT);
		let events = RuntimeEvents {
			shared: shared.clone(),
			checkpoint,
			changed: changed.clone(),
			bridge_scope: Default::default(),
		};
		let worker = DirectoryWorker {
			platform: platform.clone(),
			connections: connections.clone(),
			commands: commands.clone(),
			member_locator,
			shared: shared.clone(),
			latest,
			stopping,
			finished,
			changed,
			registration,
			budget: state::NoticeBudget::default(),
			pending: Vec::new(),
			streams: Vec::new(),
		};
		Ok((
			Self {
				connections,
				platform,
				commands,
				shared,
				stop,
				done,
				changed: changes,
			},
			worker,
			events,
			RegistrationInbox(inbox),
		))
	}

	pub fn read(&self) -> Ref<'_, Directories<P>> {
		self.shared.borrow()
	}
	pub fn changes(&self) -> watch::Receiver<()> {
		self.changed.clone()
	}
	/// Registered clients for transport composition, bounded by the checkpoint's
	/// directory capacity. Empty-name discovery clients do not authorize a
	/// signaling inbox. Reconnect and nickname replacement retire these leases.
	pub fn registered(&self) -> Vec<RegisteredDirectory<P>> {
		self.shared
			.borrow()
			.rows
			.iter()
			.filter_map(|row| {
				let live = row.live()?;
				if live.nick().is_empty() {
					return None;
				}
				Some(RegisteredDirectory {
					key: row.key.clone(),
					directory: live.directory().clone(),
				})
			})
			.collect()
	}
	/// Select the registered introducer by actual connection identity. This is
	/// independent of the embedding's incoming transport: a relay listener can
	/// still dial a WebRTC peer introduced by one of its directories.
	pub fn registered_from(&self, source: &glowcap::Session) -> Option<Directory<P>> {
		if self.is_closed() {
			return None;
		}
		self.shared.borrow().rows.iter().find_map(|row| {
			let live = row.live()?;
			(!live.nick().is_empty()
				&& row.key.scope.current()
				&& live.directory().client().session().same_session(source))
			.then(|| live.directory().clone())
		})
	}
	/// Shutdown has been requested, completed, or the worker has been dropped.
	pub fn is_closed(&self) -> bool {
		*self.stop.borrow() || self.done.borrow().is_some() || self.done.has_changed().is_err()
	}
	/// A connected directory's live client and granted nick. The caller clones
	/// the capability; this runtime keeps its own for reconnect and discovery.
	pub fn connected(
		&self,
		id: &rooms_application::session::checkpoint::reconciliation::Id,
	) -> Option<(Directory<P>, String)> {
		let state = self.shared.borrow();
		let row = state.rows.iter().find(|row| row.wanted.id.as_ref() == id)?;
		if row.phase != Phase::Connected {
			return None;
		}
		Some((row.held.as_ref()?.clone(), row.live.as_ref()?.nick().to_owned()))
	}
	/// Match the exact current connection without cloning a client or nickname.
	/// A reconnect under the same directory ID retires the prior connection.
	pub fn has_connection(&self, scope: &str, session: &glowcap::Session) -> bool {
		if self.is_closed() {
			return false;
		}
		self.shared.borrow().rows.iter().any(|row| {
			row.wanted.id.text().as_str() == Some(scope)
				&& row.phase == Phase::Connected
				&& row
					.held
					.as_ref()
					.is_some_and(|directory| directory.client().session().same_session(session))
		})
	}
	/// Transfer Share's already-held directory before its attempt starts. The
	/// registry owns its custody through registration failures and retries.
	pub fn adopt(&self, id: &DocumentText, directory: Directory<P>, nick: String) -> Result<(), Error> {
		if self.is_closed() {
			return Err(Error::closed("directory runtime is closed"));
		}
		let mut state = self.shared.borrow_mut();
		let row = state
			.rows
			.iter_mut()
			.find(|r| r.wanted.id.text() == id)
			.ok_or_else(|| Error::stale("directory is not intended"))?;
		if row.phase != Phase::Waiting || row.held.is_some() {
			return Err(Error::stale("directory acquisition already started"));
		}
		row.held = Some(directory);
		row.granted_nick = nick;
		Ok(())
	}
	pub async fn close(&self) -> Result<(), Error> {
		self.stop.send_replace(true);
		let mut done = self.done.clone();
		loop {
			if let Some(result) = done.borrow().clone() {
				return result;
			}
			done.changed()
				.await
				.map_err(|_| Error::closed("directory worker retired without completing shutdown"))?;
		}
	}
}
struct RuntimeFacts<'a, P: Platform> {
	directories: Ref<'a, Directories<P>>,
	bridge_scope: BridgeScope,
}
impl<P: Platform> Facts for RuntimeFacts<'_, P> {
	fn room_publication(&self, directory: &DocumentText, name: &DocumentText) -> Option<&DocumentText> {
		self.directories.room_publication(directory, name)
	}
	fn bridge_scope(&self, conversation: &DocumentText) -> Option<DocumentText> {
		self.bridge_scope
			.borrow()
			.as_deref()
			.and_then(|read| read(conversation))
	}
}
impl<P: Platform> Facts for Directories<P> {
	fn room_publication(&self, directory: &DocumentText, name: &DocumentText) -> Option<&DocumentText> {
		let row = self.rows.iter().find(|r| r.wanted.id.text() == directory)?;
		let room = row.live()?.view().room_named(name)?;
		(room.kind != rooms_application::directory::PublicationKind::Local).then(|| room.id.text())
	}
}
impl<P: Platform> RuntimeEvents<P> {
	pub fn set_bridge_scope(&mut self, read: impl Fn(&DocumentText) -> Option<DocumentText> + 'static) {
		*self.bridge_scope.borrow_mut() = Some(Box::new(read));
	}
}
impl<P: Platform> SessionEvents for RuntimeEvents<P> {
	async fn preparing(
		&mut self,
		_checkpoint: &rooms_application::session::checkpoint::Checkpoint,
	) -> Result<impl Sized + 'static, crate::Error> {
		Ok(())
	}

	fn facts(&self) -> impl Facts + '_ {
		RuntimeFacts {
			directories: self.shared.borrow(),
			bridge_scope: self.bridge_scope.clone(),
		}
	}
	fn changed(&mut self, _: Change, view: &SessionView) {
		match view.read(|s| s.checkpoint_handle()) {
			Ok(Ok(checkpoint)) => {
				// Withdraw stale authority synchronously with the durable commit,
				// before another command or queued direct notice can observe it.
				for row in &mut self.shared.borrow_mut().rows {
					if !checkpoint.directories().any(|intent| row.wanted.matches(intent)) {
						row.key.scope.retire();
						row.phase = Phase::Retiring;
					}
				}
				self.shared.borrow_mut().directs.reconcile(&checkpoint);
				self.checkpoint.send_replace(checkpoint);
			}
			result => {
				self.shared.borrow_mut().failure = Some(format!(
					"session checkpoint is unreadable: {}",
					match result {
						Err(e) => e.to_string(),
						Ok(Err(e)) => e.to_string(),
						_ => unreachable!(),
					}
				))
			}
		}
		self.changed.send_replace(());
	}
	fn reconciliation_issue(&mut self, fact: &Fact, error: Option<&str>) {
		self.shared.borrow_mut().fact_issue(fact, error);
		self.changed.send_replace(());
	}
}
