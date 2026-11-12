//! Shared high-level lifecycle for generic FFI-driver listeners: the one
//! bind spine every transport module hosts through, and the one binding owner
//! of an open driver listener.

use std::cell::{Cell, RefCell};
use std::future::Future;
use std::rc::Rc;

use crate::abi_constants::{DRIVER_DEFAULT_HANDSHAKE_MS, DRIVER_DEFAULT_SETTLE_MS};
use crate::driver_loop::LoopShared;
use crate::host::Host;
use crate::host::HostShared;
use crate::host::try_spawn_local_handle;
use crate::session::Session;
use crate::{ListenerIdentity, Result};

/// Bind one generic driver listener for a transport module. The spine is the
/// same for every transport: the identity becomes a Host (minted for
/// [`ListenerIdentity::Fresh`] and [`ListenerIdentity::Seed`], shared for
/// [`ListenerIdentity::Host`]), that Host establishes its driver loop,
/// `install` puts the transport's provider on the loop and returns the
/// designator to bind with whatever it made that the server keeps, the driver
/// opens the listener, `opened` turns that and the open listener into the
/// transport's own server fields, and the listener is selected as the Host's
/// advertised location. The caller wraps the returned [`LoopListener`] and
/// fields in its public server type.
///
/// One failure ladder covers every step. A listener that opened is closed
/// before the error returns, and that close's outcome rides the error as its
/// consequence. The loop is never closed here: a Host this call minted drops
/// with the error, and `HostShared::drop` closes the loop it adopted, while a
/// caller-supplied Host keeps its loop and every other listener on it.
pub(crate) async fn bind_loop_listener<Install, Installing, Installed, Opened, Fields>(
	identity: ListenerIdentity,
	transport: &str,
	install: Install,
	opened: Opened,
) -> Result<(LoopListener, Fields)>
where
	Install: FnOnce(Rc<HostShared>, Rc<LoopShared>) -> Installing,
	Installing: Future<Output = Result<(String, Installed)>>,
	Opened: FnOnce(&LoopShared, u64, String, Installed) -> Result<Fields>,
{
	let host = identity.into_host()?;
	let shared = host.shared();
	let lp = shared.ensure_driver_loop(DRIVER_DEFAULT_HANDSHAKE_MS, DRIVER_DEFAULT_SETTLE_MS)?;
	let (designator, installed) = install(shared, Rc::clone(&lp)).await?;
	let listener = lp.listen(transport, &designator).await?;
	let selected = (|| {
		let fields = opened(&lp, listener, designator, installed)?;
		lp.select_listener(listener)?;
		Ok::<_, crate::Error>(fields)
	})();
	match selected {
		Ok(fields) => Ok((LoopListener::new(lp, listener, host), fields)),
		Err(error) => Err(crate::retain_cleanup_failure(error, lp.close_listener(listener).await)),
	}
}

/// The binding's single owner for an FFI driver's generic listener handle.
/// Closing it seals admission and releases accepted sessions not yet yielded.
/// Sessions already returned to the application remain owned by their Host.
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

	/// Select this listener's locator as the Host's advertised location
	/// again. Binding a later listener on the same Host moves the selection
	/// to it, so a server that announced one listener re-selects it after
	/// every bring-up.
	pub(crate) fn select(&self) -> Result<()> {
		if self.closed.get() {
			return Err(crate::Error::from_code(crate::sys::ERR_CLOSED));
		}
		self.lp.select_listener(self.listener)
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
