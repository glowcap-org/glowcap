//! Shared high-level lifecycle for generic native-driver listeners.

use std::cell::Cell;
use std::rc::Rc;

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
}

impl LoopListener {
	pub(crate) fn new(lp: Rc<crate::driver_loop::LoopShared>, listener: u64, host: Host) -> Self {
		Self {
			lp,
			listener,
			host,
			closed: Cell::new(false),
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

	pub(crate) fn close(&self) -> Result<()> {
		if self.closed.replace(true) {
			return Ok(());
		}
		if let Err(err) = self.lp.close_listener(self.listener) {
			self.closed.set(false);
			return Err(err);
		}
		self.lp.discard_accepts(self.listener);
		Ok(())
	}
}

impl Drop for LoopListener {
	fn drop(&mut self) {
		if let Err(error) = self.close() {
			crate::record_runtime_failure(crate::FailureLayer::Binding, "loop-listener-drop-close", error);
		}
	}
}
