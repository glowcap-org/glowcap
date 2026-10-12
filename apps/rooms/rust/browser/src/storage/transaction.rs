//! Every continuation runs in the request event while IndexedDB is active.
//! Observer cancellation cannot abort the transaction or release its callbacks.
use super::{Database, Error};
use std::{
	cell::{Cell, RefCell},
	rc::{Rc, Weak},
};
use tokio::sync::Notify;
use wasm_bindgen::{JsCast, JsValue, closure::Closure};
use web_sys::{Event, IdbRequest, IdbTransaction, IdbTransactionMode};
const MAX_CALLBACKS: usize = 64;

pub(crate) struct Operation<T: 'static>(Rc<State<T>>);
pub(crate) struct Steps<T: 'static>(Rc<State<T>>);
struct State<T: 'static> {
	transaction: IdbTransaction,
	database: Database,
	data: RefCell<Option<T>>,
	failure: RefCell<Option<Error>>,
	done: Cell<bool>,
	changed: Notify,
	requests: RefCell<Vec<Request>>,
	terminal: RefCell<Option<Terminal>>,
	retained: RefCell<Option<Rc<Self>>>,
}
struct Request {
	request: IdbRequest,
	_success: Closure<dyn FnMut(Event)>,
}
impl Drop for Request {
	fn drop(&mut self) {
		self.request.set_onsuccess(None);
	}
}
struct Terminal {
	_complete: Closure<dyn FnMut(Event)>,
	_abort: Closure<dyn FnMut(Event)>,
}
impl<T> Operation<T> {
	pub fn start(
		database: &Database,
		stores: &[&str],
		mode: IdbTransactionMode,
		data: T,
		setup: impl FnOnce(&Steps<T>) -> Result<(), Error>,
	) -> Result<Self, Error> {
		let transaction = database.transaction(stores, mode)?;
		let state = Rc::new(State {
			transaction,
			database: database.clone(),
			data: RefCell::new(Some(data)),
			failure: RefCell::new(None),
			done: Cell::new(false),
			changed: Notify::new(),
			requests: RefCell::new(Vec::new()),
			terminal: RefCell::new(None),
			retained: RefCell::new(None),
		});
		let weak = Rc::downgrade(&state);
		let complete = Closure::wrap(Box::new(move |_: Event| {
			if let Some(state) = weak.upgrade() {
				state.finish(false);
			}
		}) as Box<dyn FnMut(Event)>);
		let weak = Rc::downgrade(&state);
		let abort = Closure::wrap(Box::new(move |_: Event| {
			if let Some(state) = weak.upgrade() {
				state.finish(true);
			}
		}) as Box<dyn FnMut(Event)>);
		state
			.transaction
			.set_oncomplete(Some(complete.as_ref().unchecked_ref()));
		state.transaction.set_onabort(Some(abort.as_ref().unchecked_ref()));
		*state.terminal.borrow_mut() = Some(Terminal {
			_complete: complete,
			_abort: abort,
		});
		*state.retained.borrow_mut() = Some(state.clone());
		if let Err(error) = setup(&Steps(state.clone())) {
			state.refuse(error);
		}
		Ok(Self(state))
	}
	pub async fn wait(&mut self) -> Result<T, Error> {
		while !self.0.done.get() {
			self.0.changed.notified().await;
		}
		if let Some(error) = self.0.failure.borrow().clone() {
			return Err(error);
		}
		self.0
			.data
			.borrow_mut()
			.take()
			.ok_or(Error::Invalid("browser storage outcome was already consumed"))
	}
}
impl<T> Steps<T> {
	pub fn store(&self, name: &str) -> Result<web_sys::IdbObjectStore, Error> {
		self.0.transaction.object_store(name).map_err(Into::into)
	}
	pub fn data<R>(&self, apply: impl FnOnce(&mut T) -> Result<R, Error>) -> Result<R, Error> {
		let mut data = self.0.data.borrow_mut();
		apply(data.as_mut().ok_or(Error::Closed)?)
	}
	/// A cursor reuses its callback. Simple writes need no success callback.
	/// Their errors abort the transaction and reach the same terminal owner.
	pub fn request(
		&self,
		request: IdbRequest,
		mut next: impl FnMut(&Steps<T>, JsValue) -> Result<(), Error> + 'static,
	) -> Result<(), Error> {
		if self.0.requests.borrow().len() == MAX_CALLBACKS {
			return Err(Error::Invalid("browser transaction callback budget exceeded"));
		}
		let weak: Weak<State<T>> = Rc::downgrade(&self.0);
		let current = request.clone();
		let success = Closure::wrap(Box::new(move |_: Event| {
			let Some(state) = weak.upgrade() else {
				return;
			};
			if state.done.get() || state.failure.borrow().is_some() {
				return;
			}
			let result = current
				.result()
				.map_err(Error::from)
				.and_then(|value| next(&Steps(state.clone()), value));
			if let Err(error) = result {
				state.refuse(error);
			}
		}) as Box<dyn FnMut(Event)>);
		request.set_onsuccess(Some(success.as_ref().unchecked_ref()));
		self.0.requests.borrow_mut().push(Request {
			request,
			_success: success,
		});
		Ok(())
	}
}
impl<T> State<T> {
	fn refuse(&self, error: Error) {
		if self.failure.borrow().is_none() {
			*self.failure.borrow_mut() = Some(error);
		}
		// In an active callback abort succeeds. If the browser has already
		// begun commitment, keep ownership until its real terminal event.
		let _ = self.transaction.abort();
	}
	fn finish(&self, aborted: bool) {
		if self.done.replace(true) {
			return;
		}
		if aborted && self.failure.borrow().is_none() {
			let error = self
				.transaction
				.error()
				.map(|e| Error::from(JsValue::from(e)))
				.unwrap_or(Error::Invalid("browser storage transaction aborted"));
			*self.failure.borrow_mut() = Some(error);
		}
		self.transaction.set_oncomplete(None);
		self.transaction.set_onabort(None);
		self.requests.borrow_mut().clear();
		self.terminal.borrow_mut().take();
		self.database.completed();
		self.changed.notify_waiters();
		self.retained.borrow_mut().take();
	}
}
