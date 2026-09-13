//! Browser I/O for the shared Rust Host. These adapters move opaque bytes;
//! the Host still owns framing, identity admission, and CapTP execution.
//!
//! Passing a socket transfers exclusive use of its event-handler properties.
//! Keep the resulting Channel in Session custody, or await Channel::close for
//! an unused channel. Dropping an unused channel requests closure and detaches
//! callbacks but cannot report whether the browser completed physical closure.
mod events;
mod io;
pub mod relay;
mod rtc_peer;
mod socket;
pub use rtc_peer::{RtcPeer, RtcRole};

use crate::{Channel, abi_constants::*};
use socket::Socket;
use std::{cell::RefCell, collections::VecDeque, io as std_io, rc::Rc, task::Waker};
use web_sys::{RtcDataChannel, WebSocket};

/// Open a WebSocket and immediately transfer it to a Channel. The Session's
/// handshake budget includes the opening connection. No detached open task or
/// second pre-open callback owner exists.
pub fn open_websocket(url: &str) -> std_io::Result<Channel> {
	WebSocket::new(url).map(websocket).map_err(socket::js_error)
}

/// Adopt an opening or open WebSocket carrying a byte-transparent stream.
pub fn websocket(socket: WebSocket) -> Channel {
	let shared = Shared::new(Socket::WebSocket(socket));
	let close = io::Closer::new(shared.clone());
	Channel::byte_chunks(io::Reader(shared.clone()), io::StreamWriter::new(shared), close)
}

/// Adopt an opening or open ordered, reliable RTCDataChannel. Invalid channel
/// configuration is retained as an I/O failure and retired through the same
/// observed close path. Signaling must authenticate the association between
/// remote SDP and a peer key before supplying Session identity proof; the
/// browser's DTLS implementation checks the SDP fingerprint. The caller still
/// owns the peer connection; use RtcPeer to transfer both resources together.
pub fn data_channel(channel: RtcDataChannel) -> Channel {
	data_channel_status(channel).0
}

fn data_channel_status(channel: RtcDataChannel) -> (Channel, Rc<Shared>) {
	let shared = Shared::new(Socket::DataChannel(channel));
	let close = io::Closer::new(shared.clone());
	if let Socket::DataChannel(dc) = &shared.socket {
		if !socket::ordered(dc) || dc.max_retransmits().is_some() || dc.max_packet_life_time().is_some() {
			shared.fail(
				std_io::ErrorKind::InvalidInput,
				"RTCDataChannel must be ordered and reliable",
			);
		}
	}
	(
		Channel::packets(io::Reader(shared.clone()), io::MessageWriter(shared.clone()), close),
		shared,
	)
}

#[derive(Clone)]
struct Failure(std_io::ErrorKind, String);
impl Failure {
	fn error(&self) -> std_io::Error {
		std_io::Error::new(self.0, self.1.clone())
	}
}

#[derive(Default)]
struct State {
	queue: VecDeque<Vec<u8>>,
	queued_bytes: usize,
	failure: Option<Failure>,
	closing: bool,
	closed: bool,
	reader: Option<Waker>,
	writer: Option<Waker>,
	closer: Option<Waker>,
}

impl State {
	fn wake(&mut self) {
		for waker in [&mut self.reader, &mut self.writer, &mut self.closer] {
			if let Some(waker) = waker.take() {
				waker.wake();
			}
		}
	}
	fn discard(&mut self) {
		self.queue.clear();
		self.queued_bytes = 0;
	}
	fn result(&self) -> std_io::Result<()> {
		self.failure.as_ref().map_or(Ok(()), |failure| Err(failure.error()))
	}
}

struct Shared {
	socket: Socket,
	state: RefCell<State>,
}

impl Shared {
	fn new(socket: Socket) -> Rc<Self> {
		socket.configure();
		Rc::new(Self {
			socket,
			state: RefCell::new(State::default()),
		})
	}
	fn fail(&self, kind: std_io::ErrorKind, message: impl Into<String>) {
		{
			let mut state = self.state.borrow_mut();
			if state.failure.is_none() {
				state.failure = Some(Failure(kind, message.into()));
			}
			state.discard();
			state.wake();
		}
		self.request_close();
	}
	fn request_close(&self) {
		{
			let mut state = self.state.borrow_mut();
			if state.closing || state.closed {
				return;
			}
			state.closing = true;
			state.discard();
			state.wake();
		}
		if let Err(error) = self.socket.close() {
			let mut state = self.state.borrow_mut();
			state
				.failure
				.get_or_insert_with(|| Failure(error.kind(), error.to_string()));
			// A refusal is terminal for this barrier. Its error explicitly denies
			// successful physical retirement; the closer detaches all callbacks.
			state.closed = true;
			state.wake();
		}
	}
	fn inbound_limit(&self) -> usize {
		match self.socket {
			Socket::WebSocket(_) => BINDING_WEBSOCKET_INBOUND_HIGH_WATER_BYTES,
			Socket::DataChannel(_) => WEBRTC_DATA_CHANNEL_QUEUE_BYTES,
		}
	}
}
