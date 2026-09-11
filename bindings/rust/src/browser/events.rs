use super::{Shared, Socket};
use crate::abi_constants::TRANSPORT_WEBRTC_MAX_PACKET_BYTES;
use js_sys::{ArrayBuffer, Uint8Array};
use std::{io, rc::Rc};
use wasm_bindgen::{closure::Closure, JsCast};
use web_sys::{CloseEvent, Event, MessageEvent};

// Bytes alone do not bound empty messages or queue-node overhead. A stalled
// consumer may retain at most this many event payloads on either browser API.
const MAX_QUEUED_MESSAGES: usize = 256;

pub(super) struct Events {
	message: Closure<dyn FnMut(Event)>,
	close: Closure<dyn FnMut(Event)>,
	error: Closure<dyn FnMut(Event)>,
	ready: Closure<dyn FnMut(Event)>,
}

impl Events {
	pub(super) fn install(shared: &Rc<Shared>) -> Self {
		let message = callback(shared, |shared, event| {
			if shared.state.borrow().closing || shared.state.borrow().closed {
				return;
			}
			let Some(event) = event.dyn_ref::<MessageEvent>() else {
				return;
			};
			let data = event.data();
			let Some(buffer) = data.dyn_ref::<ArrayBuffer>() else {
				shared.fail(
					io::ErrorKind::InvalidData,
					"browser channel requires binary ArrayBuffer messages",
				);
				return;
			};
			let length = buffer.byte_length() as usize;
			if matches!(shared.socket, Socket::DataChannel(_)) && length > TRANSPORT_WEBRTC_MAX_PACKET_BYTES {
				shared.fail(
					io::ErrorKind::InvalidData,
					"RTCDataChannel packet exceeds transport cap",
				);
				return;
			}
			let mut state = shared.state.borrow_mut();
			if state.queue.len() >= MAX_QUEUED_MESSAGES || length > shared.inbound_limit() - state.queued_bytes {
				drop(state);
				shared.fail(io::ErrorKind::OutOfMemory, "browser channel inbound queue exceeded");
				return;
			}
			// Admission precedes the only JS -> Wasm payload copy. PacketRead
			// transfers this Vec directly to the Host pump without another copy.
			state.queue.push_back(Uint8Array::new(buffer).to_vec());
			state.queued_bytes += length;
			if let Some(waker) = state.reader.take() {
				waker.wake();
			}
		});
		let close = callback(shared, |shared, event| {
			if let Some(event) = event.dyn_ref::<CloseEvent>() {
				if !event.was_clean() {
					shared.fail(
						io::ErrorKind::ConnectionAborted,
						format!("WebSocket closed abnormally (code {})", event.code()),
					);
				}
			}
			let mut state = shared.state.borrow_mut();
			state.closed = true;
			state.wake();
		});
		let error = callback(shared, |shared, _| {
			shared.fail(io::ErrorKind::ConnectionAborted, "browser channel error")
		});
		let ready = callback(shared, |shared, _| shared.state.borrow_mut().wake());
		let events = Self {
			message,
			close,
			error,
			ready,
		};
		events.set(&shared.socket, true);
		if shared.socket.closed() {
			shared.fail(io::ErrorKind::NotConnected, "browser channel closed before adoption");
			shared.state.borrow_mut().closed = true;
		}
		events
	}
	pub(super) fn detach(&self, socket: &Socket) {
		self.set(socket, false);
	}
	fn set(&self, socket: &Socket, attached: bool) {
		let handler = |closure| handler(closure, attached);
		match socket {
			Socket::WebSocket(ws) => {
				ws.set_onmessage(handler(&self.message));
				ws.set_onclose(handler(&self.close));
				ws.set_onerror(handler(&self.error));
				ws.set_onopen(handler(&self.ready));
			}
			Socket::DataChannel(dc) => {
				dc.set_onmessage(handler(&self.message));
				dc.set_onclose(handler(&self.close));
				dc.set_onerror(handler(&self.error));
				dc.set_onopen(handler(&self.ready));
				dc.set_onbufferedamountlow(handler(&self.ready));
			}
		}
	}
}

fn handler(closure: &Closure<dyn FnMut(Event)>, attached: bool) -> Option<&js_sys::Function> {
	attached.then(|| closure.as_ref().unchecked_ref())
}

fn callback(shared: &Rc<Shared>, mut call: impl FnMut(&Shared, Event) + 'static) -> Closure<dyn FnMut(Event)> {
	// Browser callbacks never keep the channel owner alive. The closer owns
	// these closures and unregisters them before releasing their Wasm storage.
	let weak = Rc::downgrade(shared);
	Closure::new(move |event| {
		if let Some(shared) = weak.upgrade() {
			call(&shared, event);
		}
	})
}
