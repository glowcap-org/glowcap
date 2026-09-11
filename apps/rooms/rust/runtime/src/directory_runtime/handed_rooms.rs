//! Received room capabilities have an explicit transient owner. Hosted actors
//! retain only its weak receiver; a single worker owns expiry and acceptance.
mod acceptance;
mod worker;
use super::{room_invitations::RoomLinkReceiver, AcceptedDirect, DirectoryRuntime, Generation, Platform};
use crate::session_commands::SessionCommands;
pub use acceptance::{Acceptance, ACCEPTANCE_BYTES, ACCEPTANCE_LIMIT, OBSERVER_LIMIT};
use glowcap::{Ref, Session};
use rooms_application::{
	room::handoff::{self, Handoffs, Held, View},
	session::{
		checkpoint::reconciliation::{Bearer, Field, Id},
		state::OperationId,
	},
};
use rooms_glowcap::client::Client;
use std::{
	cell::{Cell, RefCell},
	future::Future,
	pin::Pin,
	rc::{Rc, Weak},
};
use tokio::sync::watch;
pub use worker::HandedWorker;

pub struct HandedRooms<P: Platform>(Rc<State<P>>);
#[derive(Clone)]
pub struct HandedReceiver<P: Platform>(Weak<State<P>>);
struct State<P: Platform> {
	platform: P,
	rows: RefCell<Handoffs<Live<P>>>,
	source: RoomLinkReceiver<P>,
	commands: SessionCommands,
	changed: watch::Sender<()>,
	stop: watch::Sender<bool>,
	done: watch::Receiver<Option<Result<(), String>>>,
	directory_stop: watch::Receiver<bool>,
	directory_done: watch::Receiver<Option<Result<(), String>>>,
	jobs: RefCell<Vec<Weak<acceptance::Job>>>,
	queued: RefCell<Vec<Rc<acceptance::Job>>>,
	observers: Rc<Cell<usize>>,
}
struct Live<P: Platform> {
	generation: Rc<Generation>,
	client: Client<P>,
	room: Ref,
	link: RefCell<Option<Bearer>>,
	expiry: RefCell<Pin<Box<dyn Future<Output = ()>>>>,
}
impl<P: Platform> DirectoryRuntime<P> {
	/// Drive the returned worker on the same local executor. Close and observe it
	/// before closing SessionCommands; durable acceptances must finish writing.
	pub fn handed_rooms(&self) -> (HandedRooms<P>, HandedWorker<P>) {
		let (changed, _) = watch::channel(());
		let (stop, _) = watch::channel(false);
		let (finished, done) = watch::channel(None);
		let state = Rc::new(State {
			platform: self.platform.clone(),
			rows: RefCell::new(Handoffs::default()),
			source: self.room_links(),
			commands: self.commands.clone(),
			changed,
			stop,
			done,
			directory_stop: self.stop.subscribe(),
			directory_done: self.done.clone(),
			jobs: RefCell::new(Vec::new()),
			queued: RefCell::new(Vec::new()),
			observers: Rc::new(Cell::new(0)),
		});
		(HandedRooms(state.clone()), HandedWorker::new(state, finished))
	}
}
impl<P: Platform> HandedRooms<P> {
	pub fn receiver(&self) -> HandedReceiver<P> {
		HandedReceiver(Rc::downgrade(&self.0))
	}
	pub fn changes(&self) -> watch::Receiver<()> {
		self.0.changed.subscribe()
	}
	/// Borrow metadata only; no capability or bearer escapes into a view.
	pub fn read<T>(&self, read: impl FnOnce(&[&View]) -> T) -> T {
		self.0.reconcile();
		let rows = self.0.rows.borrow();
		let views: Vec<_> = rows.rows().map(Held::view).collect();
		read(&views)
	}
	pub fn decline(&self, id: &Id) -> bool {
		self.0.remove(id)
	}
	/// Admission starts owned work even if the caller drops its observation.
	/// Exact concurrent retries share the original acceptance and wire request.
	pub fn accept(&self, operation: OperationId, base: u64, id: Id, conversation: Id) -> Result<Acceptance, String> {
		self.0.accept(operation, base, id, conversation)
	}
	pub async fn close(&self) -> Result<(), String> {
		self.0.retire();
		let mut done = self.0.done.clone();
		loop {
			if let Some(result) = done.borrow().clone() {
				return result;
			}
			done.changed()
				.await
				.map_err(|_| "room-handoff worker retired without observing shutdown")?;
		}
	}
}
impl<P: Platform> Drop for HandedRooms<P> {
	fn drop(&mut self) {
		self.0.retire();
	}
}
impl<P: Platform> HandedReceiver<P> {
	/// Hosted session facets can dispose of received offers without owning shutdown.
	pub fn contains(&self, id: &Id) -> bool {
		let Some(state) = self.0.upgrade() else {
			return false;
		};
		state.reconcile();
		let present = state.rows.borrow().rows().any(|row| &row.view().id == id);
		present
	}
	pub fn decline(&self, id: &Id) -> bool {
		self.0.upgrade().is_some_and(|state| state.remove(id))
	}
	pub fn accept(&self, operation: OperationId, base: u64, id: Id, conversation: Id) -> Result<Acceptance, String> {
		self.0
			.upgrade()
			.ok_or("the room-handoff owner has ended")?
			.accept(operation, base, id, conversation)
	}

	pub fn read<T>(&self, read: impl FnOnce(&[&View]) -> T) -> T {
		let Some(state) = self.0.upgrade() else {
			return read(&[]);
		};
		state.reconcile();
		let rows = state.rows.borrow();
		let views: Vec<_> = rows.rows().map(Held::view).collect();
		read(&views)
	}
	/// Consume this received occurrence. Refusal or expiry drops only this
	/// owner's custody, never the shared Session. No link is requested here.
	pub fn receive(&self, context: &AcceptedDirect, session: Session, label: &str, room: Ref) -> Result<Id, String> {
		let state = self.0.upgrade().ok_or("the room-handoff owner has ended")?;
		state.require_open()?;
		let generation = state
			.source
			.with_directory(context, |generation, _| generation.clone())?;
		if !session.is_open() {
			return Err("the handed room connection has closed".into());
		}
		if !Field::accepts_utf16(label.encode_utf16()) {
			return Err("the handed room label is too large".into());
		}
		let id = state.source.random_id("handed-room-")?;
		let view = View {
			id: id.clone(),
			directory: context.directory().clone(),
			label: Field::new(label.into()).expect("checked label"),
			from: Field::new(context.peer().text().clone()).expect("validated sender"),
		};
		let client = Client::new(session, state.platform.clone());
		let (expiry_client, expiry_generation) = (client.clone(), generation.clone());
		let expiry = async move {
			tokio::select! {
				_ = expiry_client.session().closed() => {},
				_ = expiry_generation.scope.retired() => {},
			}
		};
		// The cached bearer has the checkpoint's 16K UTF-16 limit. Reserve its
		// worst UTF-8 retention up front; it cannot grow the custody budget later.
		let heap = generation.id.text().heap_bytes()
			+ 3 * 16384
			+ core::mem::size_of::<Generation>()
			+ core::mem::size_of_val(&expiry);
		let live = Live {
			generation,
			client,
			room,
			link: RefCell::new(None),
			expiry: RefCell::new(Box::pin(expiry)),
		};
		state.reconcile();
		state
			.rows
			.borrow_mut()
			.receive(view, live, heap)
			.map_err(|error| error.to_string())?;
		state.changed.send_replace(());
		Ok(id)
	}
}
impl<P: Platform> State<P> {
	fn require_open(&self) -> Result<(), String> {
		if *self.stop.borrow()
			|| self.done.borrow().is_some()
			|| self.done.has_changed().is_err()
			|| *self.directory_stop.borrow()
			|| self.directory_stop.has_changed().is_err()
			|| self.directory_done.borrow().is_some()
			|| self.directory_done.has_changed().is_err()
		{
			Err("the room-handoff owner has ended".into())
		} else {
			Ok(())
		}
	}
	fn current(&self, row: &Held<Live<P>>) -> bool {
		self.require_open().is_ok()
			&& row.current()
			&& row.value().generation.scope.current()
			&& row.value().client.session().is_open()
	}
	fn reconcile(&self) {
		if self.rows.borrow_mut().retain(|row| self.current(row)) {
			self.changed.send_replace(());
		}
	}
	fn remove(&self, id: &Id) -> bool {
		let removed = self.rows.borrow_mut().remove(id);
		if removed {
			self.changed.send_replace(());
		}
		removed
	}
	fn retire(&self) {
		self.stop.send_replace(true);
		self.rows.borrow_mut().close();
		self.changed.send_replace(());
	}
}
