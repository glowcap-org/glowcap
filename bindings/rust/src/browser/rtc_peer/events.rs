use super::{signal, state::Inner};
use crate::abi_constants::{WEBRTC_MAX_PENDING_ICE_CANDIDATES, WEBRTC_PENDING_ICE_CANDIDATE_QUEUE_BYTES};
use std::{io, rc::Rc};
use wasm_bindgen::{JsCast, closure::Closure};
use web_sys::{Event, RtcDataChannelEvent, RtcPeerConnection, RtcPeerConnectionIceEvent, RtcPeerConnectionState};

pub(super) struct Events {
	_candidate: Closure<dyn FnMut(Event)>,
	_channel: Closure<dyn FnMut(Event)>,
	_state: Closure<dyn FnMut(Event)>,
}
impl Events {
	pub(super) fn install(inner: &Rc<Inner>) -> Self {
		let candidate = callback(inner, |inner, event| {
			if inner.state.borrow().closing || inner.state.borrow().signaling_finished {
				return;
			}
			let Some(candidate) = event.dyn_ref::<RtcPeerConnectionIceEvent>().and_then(|e| e.candidate()) else {
				return;
			};
			let text = match signal::local_candidate(&candidate) {
				Ok(text) => text,
				Err(error) => {
					inner.fail(error.kind(), error.to_string());
					return;
				}
			};
			let mut state = inner.state.borrow_mut();
			if state.local.len() >= WEBRTC_MAX_PENDING_ICE_CANDIDATES
				|| text.len() > WEBRTC_PENDING_ICE_CANDIDATE_QUEUE_BYTES - state.local_bytes
			{
				drop(state);
				inner.fail(io::ErrorKind::OutOfMemory, "WebRTC local candidate queue exceeded");
				return;
			}
			state.local_bytes += text.len();
			state.local.push_back(text);
			state.wake();
		});
		let channel = callback(inner, |inner, event| {
			if let Some(event) = event.dyn_ref::<RtcDataChannelEvent>() {
				inner.wire(event.channel());
			}
		});
		let state = callback(inner, |inner, _| {
			if !inner.state.borrow().closing
				&& matches!(
					inner.pc.connection_state(),
					RtcPeerConnectionState::Failed | RtcPeerConnectionState::Closed
				) {
				inner.fail(
					io::ErrorKind::ConnectionAborted,
					"WebRTC could not establish or retain a route",
				);
			}
		});
		inner.pc.set_onicecandidate(Some(candidate.as_ref().unchecked_ref()));
		inner.pc.set_ondatachannel(Some(channel.as_ref().unchecked_ref()));
		inner
			.pc
			.set_onconnectionstatechange(Some(state.as_ref().unchecked_ref()));
		Self {
			_candidate: candidate,
			_channel: channel,
			_state: state,
		}
	}
	pub(super) fn detach(&self, pc: &RtcPeerConnection) {
		pc.set_onicecandidate(None);
		pc.set_ondatachannel(None);
		pc.set_onconnectionstatechange(None);
	}
}

fn callback(inner: &Rc<Inner>, mut f: impl FnMut(&Rc<Inner>, Event) + 'static) -> Closure<dyn FnMut(Event)> {
	let weak = Rc::downgrade(inner);
	Closure::new(move |event| {
		if let Some(inner) = weak.upgrade() {
			f(&inner, event);
		}
	})
}
