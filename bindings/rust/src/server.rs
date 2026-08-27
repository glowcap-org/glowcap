//! Shared high-level lifecycle for generic native-driver listeners.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use crate::host::try_spawn_local_handle;
use crate::host::Host;
use crate::session::Session;
use crate::Result;

/// The binding's single owner for a native driver's generic listener handle.
/// Closing it seals admission and releases accepted sessions not yet yielded;
/// sessions already returned to the application remain owned by their Host.
pub(crate) struct LoopListener {
	lp: Rc<crate::driver_loop::LoopShared>,
	listener: u64,
	host: Host,
	closed: Cell<bool>,
	close_outcome: RefCell<Option<Result<()>>>,
}

impl LoopListener {
	pub(crate) fn new(lp: Rc<crate::driver_loop::LoopShared>, listener: u64, host: Host) -> Self {
		Self {
			lp,
			listener,
			host,
			closed: Cell::new(false),
			close_outcome: RefCell::new(None),
		}
	}

	pub(crate) fn host(&self) -> Host {
		self.host.clone()
	}

	pub(crate) fn locator(&self) -> Result<crate::uri::Locator> {
		if self.closed.get() {
			return Err(crate::Error::from_code(crate::sys::ERR_CLOSED));
		}
		self.lp.listener_locator(self.listener)
	}

	pub(crate) async fn accept(&self) -> Result<Session> {
		if self.closed.get() {
			return Err(crate::Error::from_code(crate::sys::ERR_CLOSED));
		}
		let session = self.lp.accept(self.listener).await?;
		crate::driver_loop::loop_session(&self.lp, session)
	}

	pub(crate) async fn close(&self) -> Result<()> {
		if let Some(outcome) = self.close_outcome.borrow().as_ref() {
			return outcome.clone();
		}
		self.closed.set(true);
		let outcome = self.lp.close_listener(self.listener).await;
		let mut retained = self.close_outcome.borrow_mut();
		if let Some(first) = retained.as_ref() {
			return first.clone();
		}
		*retained = Some(outcome.clone());
		outcome
	}
}

impl Drop for LoopListener {
	fn drop(&mut self) {
		if self.close_outcome.borrow().is_some() {
			return;
		}
		self.closed.set(true);
		let lp = Rc::clone(&self.lp);
		let listener = self.listener;
		if try_spawn_local_handle(async move {
			if let Err(error) = lp.close_listener(listener).await {
				crate::record_runtime_failure(crate::FailureLayer::Binding, "loop-listener-drop-close", error);
			}
		})
		.is_some()
		{
			return;
		}
		if let Err(error) = self.lp.begin_listener_close(self.listener) {
			crate::record_runtime_failure(crate::FailureLayer::Binding, "loop-listener-drop-close", error);
		}
	}
}
