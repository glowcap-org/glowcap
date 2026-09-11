//! One connection to the existing browser archive schema. Closing stops new
//! transactions and observes active ones; a late blocked open closes its result.
use super::Error;
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
};
use tokio::sync::Notify;
use wasm_bindgen::{closure::Closure, JsCast};
use web_sys::{Event, IdbDatabase, IdbFactory, IdbOpenDbRequest, IdbTransaction, IdbTransactionMode};
mod schema;
type EventCallback = Closure<dyn FnMut(Event)>;

#[derive(Clone)]
pub struct Database(Rc<Connection>);
struct Connection {
	database: IdbDatabase,
	closing: Cell<bool>,
	active: Cell<usize>,
	changed: Notify,
	callbacks: RefCell<Option<ConnectionCallbacks>>,
}
struct ConnectionCallbacks {
	_version: Closure<dyn FnMut(Event)>,
	_closed: Closure<dyn FnMut(Event)>,
}
impl Connection {
	fn close(&self) {
		self.closing.set(true);
		self.database.close();
		self.changed.notify_waiters();
	}
}
impl Drop for Connection {
	fn drop(&mut self) {
		self.database.set_onversionchange(None);
		self.database.set_onclose(None);
		self.database.close();
	}
}
impl Database {
	pub async fn open() -> Result<Self, Error> {
		let factory: IdbFactory = js_sys::Reflect::get(&js_sys::global(), &"indexedDB".into())
			.map_err(Error::from)?
			.dyn_into()
			.map_err(|_| Error::Unavailable)?;
		let request = factory.open_with_u32("rooms-history", 1).map_err(Error::from)?;
		let opening = Opening::start(request);
		while !opening.answered.get() {
			opening.changed.notified().await;
		}
		let result = opening
			.result
			.borrow_mut()
			.take()
			.ok_or(Error::Invalid("browser open completed without a result"))?;
		result
	}
	fn adopt(database: IdbDatabase) -> Result<Self, Error> {
		if let Err(error) = schema::validate(&database) {
			database.close();
			return Err(error);
		}
		let inner = Rc::new(Connection {
			database,
			closing: Cell::new(false),
			active: Cell::new(0),
			changed: Notify::new(),
			callbacks: RefCell::new(None),
		});
		let weak = Rc::downgrade(&inner);
		let version = Closure::wrap(Box::new(move |_: Event| {
			if let Some(inner) = weak.upgrade() {
				inner.close();
			}
		}) as Box<dyn FnMut(Event)>);
		let weak = Rc::downgrade(&inner);
		let closed = Closure::wrap(Box::new(move |_: Event| {
			if let Some(inner) = weak.upgrade() {
				inner.close();
			}
		}) as Box<dyn FnMut(Event)>);
		inner
			.database
			.set_onversionchange(Some(version.as_ref().unchecked_ref()));
		inner.database.set_onclose(Some(closed.as_ref().unchecked_ref()));
		*inner.callbacks.borrow_mut() = Some(ConnectionCallbacks {
			_version: version,
			_closed: closed,
		});
		Ok(Self(inner))
	}
	pub fn is_closed(&self) -> bool {
		self.0.closing.get()
	}
	pub async fn close(&self) {
		self.0.close();
		while self.0.active.get() != 0 {
			self.0.changed.notified().await;
		}
	}
	pub(crate) fn transaction(&self, stores: &[&str], mode: IdbTransactionMode) -> Result<IdbTransaction, Error> {
		if self.is_closed() {
			return Err(Error::Closed);
		}
		if self.0.active.get() == 64 {
			return Err(Error::Invalid("browser transaction admission is full"));
		}
		let names = stores
			.iter()
			.map(|name| wasm_bindgen::JsValue::from_str(name))
			.collect::<js_sys::Array>();
		let transaction = self
			.0
			.database
			.transaction_with_str_sequence_and_mode(&names, mode)
			.map_err(Error::from)?;
		self.0.active.set(self.0.active.get() + 1);
		Ok(transaction)
	}
	pub(crate) fn completed(&self) {
		self.0.active.set(self.0.active.get() - 1);
		self.0.changed.notify_waiters();
	}
}
struct Opening {
	request: IdbOpenDbRequest,
	result: RefCell<Option<Result<Database, Error>>>,
	failure: RefCell<Option<Error>>,
	answered: Cell<bool>,
	changed: Notify,
	callbacks: RefCell<Vec<EventCallback>>,
	retained: RefCell<Option<Rc<Self>>>,
}
impl Opening {
	fn start(request: IdbOpenDbRequest) -> Rc<Self> {
		let state = Rc::new(Self {
			request,
			result: RefCell::new(None),
			failure: RefCell::new(None),
			answered: Cell::new(false),
			changed: Notify::new(),
			callbacks: RefCell::new(Vec::new()),
			retained: RefCell::new(None),
		});
		let weak = Rc::downgrade(&state);
		let upgrade = Closure::wrap(Box::new(move |_: Event| {
			let Some(state) = weak.upgrade() else {
				return;
			};
			let result = state
				.request
				.result()
				.map_err(Error::from)
				.and_then(|value| value.dyn_into::<IdbDatabase>().map_err(|_| Error::Schema))
				.and_then(|database| schema::create(&database));
			if let Err(error) = result {
				*state.failure.borrow_mut() = Some(error);
				if let Some(transaction) = state.request.transaction() {
					let _ = transaction.abort();
				}
			}
		}) as Box<dyn FnMut(Event)>);
		let weak = Rc::downgrade(&state);
		let success = Closure::wrap(Box::new(move |_: Event| {
			let Some(state) = weak.upgrade() else {
				return;
			};
			let result = state
				.request
				.result()
				.map_err(Error::from)
				.and_then(|value| value.dyn_into::<IdbDatabase>().map_err(|_| Error::Schema))
				.and_then(Database::adopt);
			// A blocked request cannot be cancelled. Once it eventually opens,
			// dropping this unobserved result closes the new connection.
			state.answer(result);
			state.release();
		}) as Box<dyn FnMut(Event)>);
		let weak = Rc::downgrade(&state);
		let error = Closure::wrap(Box::new(move |_: Event| {
			let Some(state) = weak.upgrade() else {
				return;
			};
			let error = state.failure.borrow_mut().take().unwrap_or_else(|| {
				state
					.request
					.error()
					.ok()
					.flatten()
					.map(|error| Error::from(wasm_bindgen::JsValue::from(error)))
					.unwrap_or(Error::Unavailable)
			});
			state.answer(Err(error));
			state.release();
		}) as Box<dyn FnMut(Event)>);
		let weak = Rc::downgrade(&state);
		let blocked = Closure::wrap(Box::new(move |_: Event| {
			if let Some(state) = weak.upgrade() {
				state.answer(Err(Error::Blocked));
			}
		}) as Box<dyn FnMut(Event)>);
		state
			.request
			.set_onupgradeneeded(Some(upgrade.as_ref().unchecked_ref()));
		state.request.set_onsuccess(Some(success.as_ref().unchecked_ref()));
		state.request.set_onerror(Some(error.as_ref().unchecked_ref()));
		state.request.set_onblocked(Some(blocked.as_ref().unchecked_ref()));
		*state.callbacks.borrow_mut() = vec![upgrade, success, error, blocked];
		*state.retained.borrow_mut() = Some(state.clone());
		state
	}
	fn answer(&self, result: Result<Database, Error>) {
		if !self.answered.replace(true) {
			*self.result.borrow_mut() = Some(result);
			self.changed.notify_waiters();
		}
	}
	fn release(&self) {
		self.request.set_onupgradeneeded(None);
		self.request.set_onsuccess(None);
		self.request.set_onerror(None);
		self.request.set_onblocked(None);
		self.callbacks.borrow_mut().clear();
		self.retained.borrow_mut().take();
	}
}
