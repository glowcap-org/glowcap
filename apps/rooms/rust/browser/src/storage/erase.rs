//! Explicit device deletion can remove obsolete schemas. The request retains
//! its callbacks and local erasure effects even when its observer goes away.
use super::{Database, Error, blobs::Cache, memory::Memory};
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
};
use tokio::sync::Notify;
use wasm_bindgen::{JsCast, closure::Closure};
use web_sys::{Event, IdbFactory, IdbOpenDbRequest};

type Callback = Closure<dyn FnMut(Event)>;
pub(crate) struct Eraser {
	pub(super) database: Option<Database>,
	pub(super) effects: Effects,
	pub(super) serial: Rc<tokio::sync::Mutex<()>>,
	pub(super) pending: RefCell<Option<Rc<Deletion>>>,
}
#[derive(Clone, Default)]
pub(super) struct Effects {
	pub cache: Cache,
	pub memory: Option<Memory>,
	pub erased: Rc<Cell<bool>>,
}
impl Effects {
	fn committed(&self) {
		self.erased.set(true);
		self.cache.clear();
		if let Some(memory) = &self.memory {
			memory.clear();
		}
	}
}
impl Eraser {
	pub(crate) fn detached() -> Self {
		Self {
			database: None,
			effects: Effects::default(),
			serial: Rc::default(),
			pending: RefCell::default(),
		}
	}
	pub async fn erase(&self) -> Result<(), Error> {
		let _serial = self.serial.lock().await;
		if let Some(database) = &self.database {
			database.close().await;
		}
		let prior = self.pending.borrow().clone();
		let deletion = match prior {
			Some(prior) if !prior.finished.get() => prior,
			_ => {
				let deletion = Deletion::start(self.effects.clone())?;
				*self.pending.borrow_mut() = Some(deletion.clone());
				deletion
			}
		};
		deletion.wait().await
	}
}

pub(super) struct Deletion {
	request: IdbOpenDbRequest,
	effects: Effects,
	finished: Cell<bool>,
	blocked: Cell<bool>,
	outcome: RefCell<Option<Result<(), Error>>>,
	changed: Notify,
	callbacks: RefCell<Vec<Callback>>,
	retained: RefCell<Option<Rc<Self>>>,
}
impl Deletion {
	fn start(effects: Effects) -> Result<Rc<Self>, Error> {
		let factory = js_sys::Reflect::get(&js_sys::global(), &"indexedDB".into())?
			.dyn_into::<IdbFactory>()
			.map_err(|_| Error::Unavailable)?;
		let request = factory.delete_database("rooms-history")?;
		let state = Rc::new(Self {
			request,
			effects,
			finished: Cell::new(false),
			blocked: Cell::new(false),
			outcome: RefCell::default(),
			changed: Notify::new(),
			callbacks: RefCell::default(),
			retained: RefCell::default(),
		});
		let weak = Rc::downgrade(&state);
		let success = Closure::wrap(Box::new(move |_: Event| {
			if let Some(state) = weak.upgrade() {
				state.effects.committed();
				state.finish(Ok(()));
			}
		}) as Box<dyn FnMut(Event)>);
		let weak = Rc::downgrade(&state);
		let error = Closure::wrap(Box::new(move |_: Event| {
			if let Some(state) = weak.upgrade() {
				let error = state
					.request
					.error()
					.ok()
					.flatten()
					.map(|error| Error::from(wasm_bindgen::JsValue::from(error)))
					.unwrap_or(Error::Unavailable);
				state.finish(Err(error));
			}
		}) as Box<dyn FnMut(Event)>);
		let weak = Rc::downgrade(&state);
		let blocked = Closure::wrap(Box::new(move |_: Event| {
			if let Some(state) = weak.upgrade() {
				state.blocked.set(true);
				state.changed.notify_waiters();
			}
		}) as Box<dyn FnMut(Event)>);
		state.request.set_onsuccess(Some(success.as_ref().unchecked_ref()));
		state.request.set_onerror(Some(error.as_ref().unchecked_ref()));
		state.request.set_onblocked(Some(blocked.as_ref().unchecked_ref()));
		*state.callbacks.borrow_mut() = vec![success, error, blocked];
		*state.retained.borrow_mut() = Some(state.clone());
		Ok(state)
	}
	async fn wait(&self) -> Result<(), Error> {
		loop {
			if let Some(outcome) = self.outcome.borrow().clone() {
				return outcome;
			}
			if self.blocked.get() {
				return Err(Error::Platform(
					"archive deletion is pending in another tab; close that tab and retry Delete browser data".into(),
				));
			}
			self.changed.notified().await;
		}
	}
	fn finish(&self, outcome: Result<(), Error>) {
		self.finished.set(true);
		*self.outcome.borrow_mut() = Some(outcome);
		self.changed.notify_waiters();
		self.request.set_onsuccess(None);
		self.request.set_onerror(None);
		self.request.set_onblocked(None);
		self.callbacks.borrow_mut().clear();
		self.retained.borrow_mut().take();
	}
}
/// Setup owns this handle without starting a Host. Repeated clicks observe the
/// same pending deletion; a blocked browser request cannot be cancelled.
#[wasm_bindgen::prelude::wasm_bindgen]
pub struct RoomsBrowserArchive(Rc<Eraser>);
#[wasm_bindgen::prelude::wasm_bindgen]
impl RoomsBrowserArchive {
	#[wasm_bindgen::prelude::wasm_bindgen(constructor)]
	pub fn new() -> Self {
		Self(Rc::new(Eraser::detached()))
	}
	pub fn erase(&self) -> js_sys::Promise {
		let eraser = self.0.clone();
		wasm_bindgen_futures::future_to_promise(async move {
			eraser
				.erase()
				.await
				.map(|()| wasm_bindgen::JsValue::UNDEFINED)
				.map_err(|error| js_sys::Error::new(&error.to_string()).into())
		})
	}
}
impl Default for RoomsBrowserArchive {
	fn default() -> Self {
		Self::new()
	}
}
