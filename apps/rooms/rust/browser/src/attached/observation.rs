//! Observation generations and typed file custody share the attachment's
//! lifetime. The callback keeps only a weak scope, so retiring a view cannot
//! retain itself through the published observer.
use super::{Result, driver::Driver, files, view};
use crate::platform::Platform;
use rooms_application::{
	archive::change::Change,
	session::{event::Event, snapshot::Snapshot},
};
use rooms_glowcap::client::session::{Observer, Session, Watch};
use std::{
	cell::{Cell, RefCell},
	rc::{Rc, Weak},
};
use wasm_bindgen::{JsCast, JsValue};

#[derive(Default)]
pub(super) struct Scope {
	closed: Cell<bool>,
	stopping: tokio::sync::Notify,
	generation: Cell<u64>,
	watch: RefCell<Option<Watch<Platform>>>,
	local_watch: RefCell<Option<Rc<rooms_runtime::service::LocalObservation>>>,
	files: RefCell<Vec<Weak<files::Held>>>,
}
impl Scope {
	pub fn close(&self) {
		self.closed.set(true);
		self.stopping.notify_waiters();
		self.watch.borrow_mut().take();
		if let Some(watch) = self.local_watch.borrow_mut().take() {
			watch.close();
		}
		for file in self.files.borrow_mut().drain(..).filter_map(|file| file.upgrade()) {
			file.release();
		}
	}
	pub async fn stopped(&self) {
		while !self.closed.get() {
			self.stopping.notified().await;
		}
	}
	pub fn disconnect(&self) -> Result<()> {
		self.begin()?;
		for file in self.files.borrow_mut().drain(..).filter_map(|file| file.upgrade()) {
			file.release();
		}
		Ok(())
	}
	pub fn open(&self) -> Result<()> {
		if self.closed.get() {
			Err("Rooms attachment is closed".into())
		} else {
			Ok(())
		}
	}
	pub fn keep(&self, file: &Rc<files::Held>) -> Result<()> {
		self.open()?;
		let mut files = self.files.borrow_mut();
		files.retain(|file| file.upgrade().is_some_and(|file| file.live()));
		files.push(Rc::downgrade(file));
		Ok(())
	}
	pub fn begin(&self) -> Result<u64> {
		self.open()?;
		let generation = self
			.generation
			.get()
			.checked_add(1)
			.ok_or("Rooms observation generation exhausted")?;
		self.generation.set(generation);
		self.watch.borrow_mut().take();
		if let Some(watch) = self.local_watch.borrow_mut().take() {
			watch.close();
		}
		Ok(generation)
	}
	pub fn generation(&self) -> u64 {
		self.generation.get()
	}
	pub fn current(&self, generation: u64) -> Result<()> {
		self.open()?;
		if self.generation.get() != generation {
			Err("Rooms observation was replaced".into())
		} else {
			Ok(())
		}
	}
	pub fn install(&self, generation: u64, watch: Watch<Platform>) -> Result<()> {
		self.current(generation)?;
		*self.watch.borrow_mut() = Some(watch);
		Ok(())
	}
	pub fn install_local(&self, generation: u64, watch: Rc<rooms_runtime::service::LocalObservation>) -> Result<()> {
		self.current(generation)?;
		*self.local_watch.borrow_mut() = Some(watch);
		Ok(())
	}
	pub fn local_observation(&self) -> Result<Rc<rooms_runtime::service::LocalObservation>> {
		self.open()?;
		self.local_watch
			.borrow()
			.clone()
			.ok_or_else(|| "Local Rooms observation has not started".into())
	}
}
impl Drop for Scope {
	fn drop(&mut self) {
		self.close();
	}
}

pub(super) struct Callbacks {
	pub owner: Weak<super::owner::Owner>,
	pub scope: Weak<Scope>,
	pub generation: u64,
	pub driver: Driver,
	pub latest: Rc<RefCell<Option<Rc<Snapshot>>>>,
	pub notified: Rc<tokio::sync::Notify>,
	pub operations: js_sys::Function,
	pub history: js_sys::Function,
}
impl Callbacks {
	fn scope(&self) -> Result<Rc<Scope>> {
		self.driver.require_open()?;
		let scope = self.scope.upgrade().ok_or("Rooms observation retired")?;
		scope.current(self.generation)?;
		Ok(scope)
	}
}
impl Callbacks {
	pub fn changed(&self, snapshot: Snapshot) -> Result<()> {
		self.scope()?;
		let snapshot = Rc::new(snapshot);
		{
			let mut latest = self.latest.borrow_mut();
			if latest
				.as_ref()
				.is_some_and(|old| old.revision.get() > snapshot.revision.get())
			{
				return Ok(());
			}
			*latest = Some(snapshot.clone());
		}
		self.notified.notify_waiters();
		self.owner.upgrade().ok_or("Rooms attachment retired")?.announce(None)
	}
	pub fn event<C>(
		&self,
		event: Event<C>,
		file: impl Fn(rooms_application::room::attachment::Attachment<C>) -> files::Access,
	) -> Result<()> {
		let scope = self.scope()?;
		let owner = self.owner.upgrade().ok_or("Rooms attachment retired")?;
		if let Some((conversation, reason)) = owner.events.receive(&self.driver, &scope, event, file)? {
			owner.event_gap(conversation, reason)?;
			owner.history.invalidate(&Change::All)?;
			call(&self.history, JsValue::NULL)?;
		}
		Ok(())
	}

	pub fn operations_changed(&self, scope: &str) -> Result<()> {
		self.scope()?;
		self.owner
			.upgrade()
			.ok_or("Rooms attachment retired")?
			.operations
			.invalidate(scope)?;
		call(&self.operations, scope.into())
	}
	pub fn history_changed(&self, change: Change) -> Result<()> {
		self.scope()?;
		self.owner
			.upgrade()
			.ok_or("Rooms attachment retired")?
			.history
			.invalidate(&change)?;
		call(&self.history, view::history_change(change)?)
	}
}
pub(super) struct RemoteCallbacks {
	pub callbacks: Callbacks,
	pub session: Session<Platform>,
}
impl Observer for RemoteCallbacks {
	fn changed(&mut self, snapshot: Snapshot) -> Result<()> {
		self.callbacks.changed(snapshot)
	}
	fn event(&mut self, event: Event<glowcap::Ref>) -> Result<()> {
		self.callbacks.event(event, |file| self.session.attachment(file).into())
	}
	fn operations_changed(&mut self, scope: &str) -> Result<()> {
		self.callbacks.operations_changed(scope)
	}
	fn history_changed(&mut self, change: Change) -> Result<()> {
		self.callbacks.history_changed(change)
	}
}
pub(super) struct LocalCallbacks {
	pub callbacks: Callbacks,
	pub session: rooms_runtime::service::Local<Platform>,
	pub source: String,
	pub sequence: Cell<u64>,
}
/// A notice this page's callbacks could not take. The runtime retires an
/// observer that fails, so the view really is gone by the time anyone reads
/// this; the page's own sentence rides along for whoever shows it.
fn unobservable(reason: impl Into<String>) -> rooms_runtime::Error {
	rooms_runtime::Error::closed(reason.into())
}

impl rooms_runtime::service::LocalObserver for LocalCallbacks {
	fn changed(&self) -> std::result::Result<(), rooms_runtime::service::error::Error> {
		self.callbacks.changed(self.session.snapshot()?).map_err(unobservable)
	}
	fn event(
		&self,
		event: &rooms_runtime::rooms::ConversationEvent,
	) -> std::result::Result<(), rooms_runtime::service::error::Error> {
		use rooms_runtime::service::error::Error;
		let sequence = self
			.sequence
			.get()
			.checked_add(1)
			.filter(|n| *n < (1 << 53))
			.ok_or_else(|| Error::exhausted("Local Rooms event sequence exhausted"))?;
		self.sequence.set(sequence);
		self.callbacks
			.event(
				event.project(&self.source, sequence).map_err(Error::invalid_by)?,
				|file| file.blob.into(),
			)
			.map_err(unobservable)
	}
	fn operations_changed(&self, scope: &str) -> std::result::Result<(), rooms_runtime::service::error::Error> {
		self.callbacks.operations_changed(scope).map_err(unobservable)
	}
	fn history_changed(&self, change: &Change) -> std::result::Result<(), rooms_runtime::service::error::Error> {
		self.callbacks.history_changed(change.clone()).map_err(unobservable)
	}
	fn closed(&self) {
		if let Some(scope) = self.callbacks.scope.upgrade() {
			if scope.generation() == self.callbacks.generation {
				scope.close();
			}
		}
	}
}
pub(super) fn call(function: &js_sys::Function, argument: JsValue) -> Result<()> {
	function
		.call1(&JsValue::UNDEFINED, &argument)
		.map(|_| ())
		.map_err(|error| {
			error
				.dyn_ref::<js_sys::Error>()
				.map(|error| String::from(error.message()))
				.or_else(|| error.as_string())
				.unwrap_or_else(|| "Rooms view callback failed".into())
		})
}
