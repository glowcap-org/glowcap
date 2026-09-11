use crate::abi_constants::*;
use std::io;
use wasm_bindgen::{prelude::wasm_bindgen, JsCast, JsValue};
use web_sys::{BinaryType, RtcDataChannel, RtcDataChannelState, RtcDataChannelType, WebSocket};

pub(super) enum Socket {
	WebSocket(WebSocket),
	DataChannel(RtcDataChannel),
}

// web-sys 0.3.105 omits the standard `ordered` getter. Keep the missing Web IDL
// member typed at this platform seam, alongside its generated siblings.
#[wasm_bindgen]
extern "C" {
	#[wasm_bindgen(extends = RtcDataChannel, js_name = RTCDataChannel)]
	type OrderedDataChannel;
	#[wasm_bindgen(method, getter)]
	fn ordered(this: &OrderedDataChannel) -> bool;
}

pub(super) fn ordered(channel: &RtcDataChannel) -> bool {
	channel.unchecked_ref::<OrderedDataChannel>().ordered()
}

impl Socket {
	pub(super) fn configure(&self) {
		match self {
			Self::WebSocket(ws) => ws.set_binary_type(BinaryType::Arraybuffer),
			Self::DataChannel(dc) => {
				dc.set_binary_type(RtcDataChannelType::Arraybuffer);
				dc.set_buffered_amount_low_threshold(WEBRTC_DATA_CHANNEL_QUEUE_BYTES as u32);
			}
		}
	}
	pub(super) fn open(&self) -> bool {
		match self {
			Self::WebSocket(ws) => ws.ready_state() == WebSocket::OPEN,
			Self::DataChannel(dc) => dc.ready_state() == RtcDataChannelState::Open,
		}
	}
	pub(super) fn connecting(&self) -> bool {
		match self {
			Self::WebSocket(ws) => ws.ready_state() == WebSocket::CONNECTING,
			Self::DataChannel(dc) => dc.ready_state() == RtcDataChannelState::Connecting,
		}
	}
	pub(super) fn closed(&self) -> bool {
		match self {
			Self::WebSocket(ws) => ws.ready_state() == WebSocket::CLOSED,
			Self::DataChannel(dc) => dc.ready_state() == RtcDataChannelState::Closed,
		}
	}
	pub(super) fn buffered(&self) -> usize {
		match self {
			Self::WebSocket(ws) => ws.buffered_amount() as usize,
			Self::DataChannel(dc) => dc.buffered_amount() as usize,
		}
	}
	pub(super) fn close(&self) -> io::Result<()> {
		match self {
			Self::WebSocket(ws) => ws.close().map_err(js_error),
			Self::DataChannel(dc) => {
				dc.close();
				Ok(())
			}
		}
	}
	pub(super) fn send(&self, bytes: &[u8]) -> io::Result<()> {
		// web-sys passes a borrowed view of linear memory to the synchronous
		// browser send. The platform copies into its send buffer before returning;
		// no JS view escapes and no binding-owned outbound buffer is allocated.
		match self {
			Self::WebSocket(ws) => ws.send_with_u8_array(bytes),
			Self::DataChannel(dc) => dc.send_with_u8_array(bytes),
		}
		.map_err(js_error)
	}
}

pub(super) fn js_error(error: JsValue) -> io::Error {
	io::Error::other(format!("browser channel: {error:?}"))
}
