//! Transport-neutral connection and handoff dialing.
//!
//! Native I/O enters through an explicitly selected [`Provider`]; an embedder
//! that owns channel establishment supplies a [`Connector`]. Transport modules
//! construct both values and own locator interpretation. This module owns only
//! Host lifetime, loop adoption, handshake budgets, and terminal reporting of
//! byte-fed DIAL actions.

use std::rc::Rc;
use std::time::Duration;

use crate::host::{Host, HostShared};
use crate::session::{Session, HANDSHAKE_TIMEOUT};
use crate::uri::{Locator, OwnedLocator};
use crate::{sys, Connector, Error, Result, TransportOperationOptions};

pub(crate) async fn dial_with_connector(
	connector: Connector,
	locator: &Locator,
	host: Host,
	redeem: bool,
	transport_options: Option<&[u8]>,
	handshake_timeout: Option<Duration>,
) -> Result<Session> {
	if !connector.supports(&locator.transport) {
		return Err(Error::with_detail(
			sys::ERR_INVALID_ARGUMENT,
			format!("connector does not advertise transport {:?}", locator.transport),
		));
	}
	if host.shared().driver_loop().is_some() {
		return Err(Error::with_detail(
			sys::ERR_INVALID_ARGUMENT,
			"a native-loop Host cannot open an embedder-owned byte channel".to_string(),
		));
	}
	let session = connector
		.connect(host, locator, redeem, transport_options, handshake_timeout)
		.await?;
	Ok(session)
}

pub(crate) async fn dial_exporter(locator: &Locator, host: Rc<HostShared>) -> Result<Session> {
	let host = Host::from_shared(host);
	let connector = host.shared().connector(&locator.transport).ok_or_else(|| {
		Error::with_detail(
			sys::ERR_INVALID_ARGUMENT,
			format!("byte-fed Host has no connector for transport {:?}", locator.transport),
		)
	})?;
	dial_with_connector(connector, locator, host, true, None, Some(HANDSHAKE_TIMEOUT)).await
}

/// Execute one byte-fed Host DIAL action and report its terminal result.
pub(crate) async fn run_dial_ticket(host: &Rc<HostShared>, ticket: u64, route_index: usize) -> Result<()> {
	use crate::host::{check_host, try_spawn_local};
	use crate::sys::host as ffi;

	let mut opened: Option<Session> = None;
	let result: Result<()> = async {
		let mut view = unsafe { core::mem::zeroed::<sys::PancakeLocatorView>() };
		let mut hint_count = 0usize;
		let mut hints: Vec<sys::PancakeLocatorHintView>;
		let probe_rc = unsafe {
			ffi::pancake_host_pending_dial(
				host.raw(),
				ticket,
				route_index,
				core::ptr::null_mut(),
				0,
				&mut view,
				&mut hint_count,
			)
		};
		if probe_rc == sys::ERR_BUFFER_TOO_SMALL {
			hints = vec![unsafe { core::mem::zeroed::<sys::PancakeLocatorHintView>() }; hint_count];
			check_host(unsafe {
				ffi::pancake_host_pending_dial(
					host.raw(),
					ticket,
					route_index,
					hints.as_mut_ptr(),
					hints.len(),
					&mut view,
					&mut hint_count,
				)
			})?;
		} else {
			check_host(probe_rc)?;
		}
		let locator = OwnedLocator::clone_view(&view)?.value()?;
		let session = Box::pin(dial_exporter(&locator, Rc::clone(host))).await?;
		host.guard_handle()?;
		let raw_session = session.raw_session();
		opened = Some(session);
		// Admit the owner task before reporting the connection to the core. Once
		// `pancake_host_dialed` commits, failure is no longer retryable as a dial;
		// this gate keeps task admission on the refusal side of that boundary.
		let (serve_tx, serve_rx) = tokio::sync::oneshot::channel::<Session>();
		if !try_spawn_local(async move {
			if let Ok(session) = serve_rx.await {
				let serving = session.serve();
				if serving.await.is_err() {
					session.close_transport();
				}
				drop(session);
			}
		}) {
			return Err(Error::with_detail(
				sys::ERR_INTERNAL,
				"dial completion requires a running LocalSet".to_string(),
			));
		}
		let mut adopted = 0u8;
		check_host(unsafe { ffi::pancake_host_dialed(host.raw(), ticket, route_index, raw_session, &mut adopted) })?;
		if adopted == 0 {
			let session = opened.take().expect("unadopted dial remains owned");
			session.close(crate::PendingWork::Cancel).await?;
			return Ok(());
		}
		let session = opened.take().expect("reported session remains owned");
		serve_tx.send(session).map_err(|_| {
			Error::with_detail(
				sys::ERR_INTERNAL,
				"the admitted dial owner task ended before handoff".to_string(),
			)
		})?;
		Ok(())
	}
	.await;
	match result {
		Ok(()) => Ok(()),
		Err(error) => {
			if let Some(session) = opened.take() {
				if let Err(cleanup) = session.close(crate::PendingWork::Cancel).await {
					host.record_background_failure(error.clone().with_secondary(cleanup));
				}
			}
			if host.closing() {
				return Ok(());
			}
			let reason = error.to_string();
			check_host(unsafe {
				ffi::pancake_host_dial_failed(host.raw(), ticket, route_index, reason.as_ptr(), reason.len())
			})
		}
	}
}

/// Per-operation connection policy.
///
/// Runtime composition and handshake policy are configured once on
/// [`crate::RuntimeConfig`]. This value carries only typed overrides for this
/// dial, and its borrowed wire representation remains valid for the complete
/// connect future.
#[derive(Clone, Copy, Debug, Default)]
pub struct ConnectOptions<'a> {
	transport: Option<&'a dyn TransportOperationOptions>,
}

impl<'a> ConnectOptions<'a> {
	/// Borrow one transport package's typed policy for this operation.
	pub fn with_transport(mut self, options: &'a dyn TransportOperationOptions) -> Self {
		self.transport = Some(options);
		self
	}

	pub(crate) fn transport_options(&self, locator: &Locator) -> Result<Option<&'a [u8]>> {
		if let Some(options) = self.transport {
			if !options.supports(&locator.transport) {
				return Err(Error::with_detail(
					sys::ERR_INVALID_ARGUMENT,
					format!("connection options do not apply to transport {:?}", locator.transport),
				));
			}
			return Ok(Some(options.as_bytes()));
		}
		Ok(None)
	}
}
