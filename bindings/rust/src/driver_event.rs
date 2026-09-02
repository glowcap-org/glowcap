//! Owned, validated projection of the driver's borrowed event record.

use crate::host_action_gen::{self, HostAction};
use crate::sys::{self, driver::GlowcapDriverEvent, host as ffi_host};
use crate::{Error, Result};

pub enum LoopEvent {
	Opened {
		operation_id: u64,
		session: *mut ffi_host::GlowcapHostSession,
	},
	OpenFailed {
		operation_id: u64,
		failure: DriverEventFailure,
	},
	ListenerReady {
		listener: u64,
	},
	ListenerFailed {
		listener: u64,
		failure: DriverEventFailure,
	},
	Accepted {
		listener: u64,
		session: *mut ffi_host::GlowcapHostSession,
	},
	SessionClosed {
		session: *mut ffi_host::GlowcapHostSession,
		failure: Option<DriverEventFailure>,
	},
	Completion(HostAction),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DriverEventFailure {
	pub primary_result: i32,
	pub primary_name: String,
	pub secondary_result: i32,
	pub secondary_count: u32,
	pub carrier: Option<crate::CarrierFailure>,
	pub secondary_name: String,
}

pub(crate) fn decode(event: &GlowcapDriverEvent) -> Result<LoopEvent> {
	match event.kind {
		sys::DRIVER_EVENT_OPENED => Ok(LoopEvent::Opened {
			operation_id: event.operation_id,
			session: event.session,
		}),
		sys::DRIVER_EVENT_OPEN_FAILED => Ok(LoopEvent::OpenFailed {
			operation_id: event.operation_id,
			failure: decode_failure(event)?,
		}),
		sys::DRIVER_EVENT_LISTENER_READY => Ok(LoopEvent::ListenerReady {
			listener: event.listener_id,
		}),
		sys::DRIVER_EVENT_LISTENER_FAILED => Ok(LoopEvent::ListenerFailed {
			listener: event.listener_id,
			failure: decode_failure(event)?,
		}),
		sys::DRIVER_EVENT_ACCEPTED => Ok(LoopEvent::Accepted {
			listener: event.listener_id,
			session: event.session,
		}),
		sys::DRIVER_EVENT_SESSION_CLOSED => Ok(LoopEvent::SessionClosed {
			session: event.session,
			failure: if event.primary_result == sys::OK {
				None
			} else {
				Some(decode_failure(event)?)
			},
		}),
		sys::DRIVER_EVENT_COMPLETION => Ok(LoopEvent::Completion(host_action_gen::decode(&event.action)?)),
		_ => Err(Error::with_detail(
			sys::ERR_INTERNAL,
			format!("driver returned unknown event kind {}", event.kind),
		)),
	}
}

fn decode_failure(event: &GlowcapDriverEvent) -> Result<DriverEventFailure> {
	Ok(DriverEventFailure {
		primary_result: event.primary_result,
		primary_name: text(event.primary_name, event.primary_name_len, "primary failure name")?,
		secondary_result: event.secondary_result,
		secondary_count: event.secondary_count,
		carrier: crate::carrier_failure::decode(
			event.carrier_phase,
			event.carrier_detail_flags,
			event.carrier_verification_flags,
			event.carrier_peer_alert,
			event.carrier_engine_code,
		)?,
		secondary_name: text(event.secondary_name, event.secondary_name_len, "secondary failure name")?,
	})
}

fn text(ptr: *const u8, len: usize, field: &str) -> Result<String> {
	if len == 0 {
		return Ok(String::new());
	}
	if ptr.is_null() {
		return Err(Error::with_detail(
			sys::ERR_INTERNAL,
			format!("driver returned null {field} with nonzero length"),
		));
	}
	let bytes = unsafe { core::slice::from_raw_parts(ptr, len) };
	let value = core::str::from_utf8(bytes)
		.map_err(|_| Error::with_detail(sys::ERR_INTERNAL, format!("driver returned non-UTF-8 {field}")))?;
	Ok(value.to_owned())
}

pub(crate) fn failure_error(failure: DriverEventFailure, operation: &str) -> Error {
	let detail = if failure.primary_name.is_empty() {
		format!("{operation} failed")
	} else {
		format!("{operation} failed: {}", failure.primary_name)
	};
	let mut error = Error::with_detail(failure.primary_result, detail).with_carrier_failure(failure.carrier);
	if failure.secondary_count != 0 {
		error = error.with_secondary(Error::with_detail(failure.secondary_result, failure.secondary_name));
		error.secondary_count = failure.secondary_count;
	}
	error
}
