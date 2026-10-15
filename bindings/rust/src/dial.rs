//! Transport-neutral connection and handoff dialing.
//!
//! FFI I/O enters through an explicitly selected [`Provider`]. An embedder
//! that owns channel establishment supplies a [`Connector`]. Transport modules
//! construct both values and own locator interpretation. This module owns only
//! Host lifetime, loop adoption, handshake budgets, and terminal reporting of
//! byte-fed DIAL actions.

use std::rc::Rc;
use std::time::Duration;

use crate::host::{Host, HostShared};
use crate::session::{HANDSHAKE_TIMEOUT, Session};
use crate::uri::{Locator, OwnedLocator};
use crate::{Connector, DialOrigin, Error, Result, TransportOperationOptions, sys};

pub(crate) async fn dial_with_connector(
	connector: Connector,
	locator: &Locator,
	host: Host,
	origin: DialOrigin,
	transport_options: Option<&[u8]>,
	handshake_timeout: Option<Duration>,
) -> Result<Session> {
	if !connector.supports(&locator.transport) {
		return Err(Error::with_detail(
			sys::ERR_INVALID_ARGUMENT,
			format!("connector does not advertise transport {:?}", locator.transport),
		));
	}
	#[cfg(not(target_arch = "wasm32"))]
	if host.shared().driver_loop().is_some() {
		return Err(Error::with_detail(
			sys::ERR_INVALID_ARGUMENT,
			"a driver-loop Host cannot open an embedder-owned byte channel".to_string(),
		));
	}
	let session = connector
		.connect(host, locator, origin, transport_options, handshake_timeout)
		.await?;
	Ok(session)
}

pub(crate) async fn dial_exporter(locator: &Locator, host: Rc<HostShared>, origin: DialOrigin) -> Result<Session> {
	let host = Host::from_shared(host);
	let connector = host.shared().connector(&locator.transport).ok_or_else(|| {
		Error::with_detail(
			sys::ERR_INVALID_ARGUMENT,
			format!("byte-fed Host has no connector for transport {:?}", locator.transport),
		)
	})?;
	dial_with_connector(connector, locator, host, origin, None, Some(HANDSHAKE_TIMEOUT)).await
}

/// Execute one byte-fed Host DIAL action and report its terminal result.
pub(crate) async fn run_dial_ticket(host: &Rc<HostShared>, ticket: u64, route_index: usize) -> Result<()> {
	use crate::host::{check_host, try_spawn_local};
	use crate::sys::host as ffi;

	let mut opened: Option<Session> = None;
	let result: Result<()> = async {
		// SAFETY: `GlowcapLocatorView` is a plain C struct of integers and null pointers; all-zero is a valid value,
		// and `glowcap_host_pending_dial` fills it before it is read.
		let mut view = unsafe { core::mem::zeroed::<sys::GlowcapLocatorView>() };
		let mut hint_count = 0usize;
		let mut hints: Vec<sys::GlowcapLocatorHintView>;
		// SAFETY: `host.raw()` is the `HostShared` handle held by this `Rc`, which the callee refuses as a null host
		// once teardown has cleared it; `ticket` and `route_index` are plain integers, and the null hint storage with
		// capacity zero is the size probe; `view` and `hint_count` are local out-parameters.
		let probe_rc = unsafe {
			ffi::glowcap_host_pending_dial(
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
			// SAFETY: `GlowcapLocatorHintView` is a plain C struct of integers and null pointers; all-zero is a valid
			// value, and the second `glowcap_host_pending_dial` call fills each element before it is read.
			hints = vec![unsafe { core::mem::zeroed::<sys::GlowcapLocatorHintView>() }; hint_count];
			// SAFETY: as the `glowcap_host_pending_dial` probe call above for `host.raw()`, `ticket`, `route_index`,
			// `view` and `hint_count`; `hints` is a live local `Vec` of `hints.len()` elements, the exact capacity the
			// probe reported, which the callee fills during the call and which stays alive as the storage behind
			// `view`.
			check_host(unsafe {
				ffi::glowcap_host_pending_dial(
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
		// Resolve the borrowed core session before yielding. This is a view of
		// the existing wrapper, never an extra owner of its transport lifetime.
		let mut source = core::ptr::null_mut();
		// SAFETY: as the `glowcap_host_pending_dial` probe call above for `host.raw()`, `ticket` and `route_index`;
		// `source` is a local out-parameter the callee fills with a session handle borrowed from a live session, which
		// is only looked up and never released here.
		check_host(unsafe { ffi::glowcap_host_pending_dial_introducer(host.raw(), ticket, route_index, &mut source) })?;
		let introducer = if source.is_null() {
			None
		} else {
			Some(Session::view(host.session_for_ptr(source).ok_or_else(|| {
				Error::with_detail(
					sys::ERR_INTERNAL,
					"pending dial introducer has no byte-fed session wrapper".into(),
				)
			})?))
		};
		let origin = DialOrigin::Pending { introducer };
		let session = Box::pin(dial_exporter(&locator, Rc::clone(host), origin)).await?;
		host.guard_handle()?;
		let raw_session = session.raw_session();
		opened = Some(session);
		// Admit the owner task before reporting the connection to the core. Once
		// `glowcap_host_dialed` commits, failure is no longer retryable as a dial;
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
		// SAFETY: as the `glowcap_host_pending_dial` probe call above for `host.raw()`, `ticket` and `route_index`;
		// `raw_session` is the handle of `opened`, the live `Session` this task still owns, and `adopted` is a local
		// out-parameter the callee writes.
		check_host(unsafe { ffi::glowcap_host_dialed(host.raw(), ticket, route_index, raw_session, &mut adopted) })?;
		if adopted == 0 {
			let session = opened.take().expect("unadopted dial remains owned");
			session.close(crate::PendingWork::Cancel).await?;
			return Ok(());
		}
		let session = opened
			.take()
			.expect("reported session remains owned")
			.into_host_retained();
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
			if let Some(session) = opened.take()
				&& let Err(cleanup) = session.close(crate::PendingWork::Cancel).await
			{
				host.record_background_failure(error.clone().with_secondary(cleanup));
			}
			if host.closing() {
				return Ok(());
			}
			let reason = error.to_string();
			// SAFETY: as the `glowcap_host_pending_dial` probe call above for `host.raw()`, `ticket` and `route_index`;
			// `reason` is a live local `String` borrowed for the call, and the callee reads it only during the call.
			check_host(unsafe {
				ffi::glowcap_host_dial_failed(host.raw(), ticket, route_index, reason.as_ptr(), reason.len())
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
