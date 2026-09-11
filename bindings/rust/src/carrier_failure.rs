//! Typed, vendor-neutral projection of a native carrier failure location.

#[cfg(all(feature = "async", not(target_arch = "wasm32")))]
use crate::{Error, Result};

#[non_exhaustive]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CarrierPhase {
	Resolve,
	Connect,
	SecureHandshake,
	WebSocketUpgrade,
	Registration,
	Receive,
	Transmit,
	Shutdown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CarrierFailure {
	pub phase: CarrierPhase,
	pub verification_flags: u32,
	pub peer_alert: Option<u8>,
	pub engine_code: Option<i32>,
}

#[cfg(all(feature = "async", not(target_arch = "wasm32")))]
pub(crate) fn decode(
	phase: u32,
	detail_flags: u32,
	verification_flags: u32,
	peer_alert: u32,
	engine_code: i32,
) -> Result<Option<CarrierFailure>> {
	use crate::abi_constants_gen as c;
	if phase == c::CARRIER_PHASE_NONE {
		if detail_flags == 0 && verification_flags == 0 && peer_alert == 0 && engine_code == 0 {
			return Ok(None);
		}
		return Err(invalid("carrier detail without a carrier phase"));
	}
	let phase = match phase {
		c::CARRIER_PHASE_RESOLVE => CarrierPhase::Resolve,
		c::CARRIER_PHASE_CONNECT => CarrierPhase::Connect,
		c::CARRIER_PHASE_SECURE_HANDSHAKE => CarrierPhase::SecureHandshake,
		c::CARRIER_PHASE_WEBSOCKET_UPGRADE => CarrierPhase::WebSocketUpgrade,
		c::CARRIER_PHASE_REGISTRATION => CarrierPhase::Registration,
		c::CARRIER_PHASE_RECEIVE => CarrierPhase::Receive,
		c::CARRIER_PHASE_TRANSMIT => CarrierPhase::Transmit,
		c::CARRIER_PHASE_SHUTDOWN => CarrierPhase::Shutdown,
		other => return Err(invalid(&format!("unknown carrier phase {other}"))),
	};
	let known = c::CARRIER_DETAIL_PEER_ALERT | c::CARRIER_DETAIL_ENGINE_CODE;
	if detail_flags & !known != 0
		|| (detail_flags & c::CARRIER_DETAIL_PEER_ALERT == 0 && peer_alert != 0)
		|| (detail_flags & c::CARRIER_DETAIL_PEER_ALERT != 0 && peer_alert > u8::MAX.into())
		|| (detail_flags & c::CARRIER_DETAIL_ENGINE_CODE == 0 && engine_code != 0)
	{
		return Err(invalid("inconsistent carrier failure detail"));
	}
	Ok(Some(CarrierFailure {
		phase,
		verification_flags,
		peer_alert: (detail_flags & c::CARRIER_DETAIL_PEER_ALERT != 0).then_some(peer_alert as u8),
		engine_code: (detail_flags & c::CARRIER_DETAIL_ENGINE_CODE != 0).then_some(engine_code),
	}))
}

#[cfg(all(feature = "async", not(target_arch = "wasm32")))]
fn invalid(detail: &str) -> Error {
	Error::with_detail(crate::sys::ERR_INTERNAL, format!("driver returned {detail}"))
}
