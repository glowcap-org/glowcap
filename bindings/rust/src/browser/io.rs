use super::{events::Events, Shared};
use crate::{abi_constants::*, ChannelClose, PacketRead, PacketWrite};
use gloo_timers::future::TimeoutFuture;
use std::{
	future::Future,
	io,
	pin::Pin,
	rc::Rc,
	task::{Context, Poll},
};
use tokio::io::AsyncWrite;

pub(super) struct Reader(pub(super) Rc<Shared>);
impl PacketRead for Reader {
	fn poll_packet(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<Option<Vec<u8>>>> {
		let mut state = self.0.state.borrow_mut();
		state.result()?;
		if let Some(packet) = state.queue.pop_front() {
			state.queued_bytes -= packet.len();
			return Poll::Ready(Ok(Some(packet)));
		}
		if state.closed || state.closing {
			return Poll::Ready(Ok(None));
		}
		state.reader = Some(cx.waker().clone());
		Poll::Pending
	}
}

pub(super) fn ready(shared: &Shared, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
	let mut state = shared.state.borrow_mut();
	state.result()?;
	if state.closing || state.closed || (!shared.socket.open() && !shared.socket.connecting()) {
		return Poll::Ready(Err(io::Error::new(io::ErrorKind::BrokenPipe, "browser channel closed")));
	}
	state.writer = Some(cx.waker().clone());
	if shared.socket.open() {
		Poll::Ready(Ok(()))
	} else {
		Poll::Pending
	}
}

pub(super) struct StreamWriter {
	shared: Rc<Shared>,
	drain: Option<TimeoutFuture>,
}
impl StreamWriter {
	pub(super) fn new(shared: Rc<Shared>) -> Self {
		Self { shared, drain: None }
	}
	fn writable(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<usize>> {
		std::task::ready!(ready(&self.shared, cx))?;
		loop {
			let capacity = BINDING_WEBSOCKET_SEND_HIGH_WATER_BYTES.saturating_sub(self.shared.socket.buffered());
			if capacity != 0 {
				self.drain = None;
				return Poll::Ready(Ok(capacity));
			}
			// WebSocket has no bufferedamountlow event. There is only one timer
			// per blocked writer, cancelled when the writer retires or drains.
			let timer = self
				.drain
				.get_or_insert_with(|| TimeoutFuture::new(BINDING_WEBSOCKET_DRAIN_POLL_MS as u32));
			std::task::ready!(Pin::new(timer).poll(cx));
			self.drain = None;
		}
	}
}
impl AsyncWrite for StreamWriter {
	fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, bytes: &[u8]) -> Poll<io::Result<usize>> {
		let capacity = std::task::ready!(self.writable(cx))?;
		let length = bytes.len().min(capacity);
		self.shared.socket.send(&bytes[..length])?;
		Poll::Ready(Ok(length))
	}
	fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
		self.writable(cx).map_ok(|_| ())
	}
	fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
		self.shared.request_close();
		// Physical completion belongs to Closer, which remains alive after the
		// pump releases both read and write halves.
		Poll::Ready(Ok(()))
	}
}

pub(super) struct MessageWriter(pub(super) Rc<Shared>);
impl PacketWrite for MessageWriter {
	fn poll_packet(&mut self, cx: &mut Context<'_>, prefix: &[u8], body: &[u8]) -> Poll<io::Result<()>> {
		if !prefix.is_empty() || body.len() > TRANSPORT_WEBRTC_MAX_PACKET_BYTES {
			return Poll::Ready(Err(io::Error::new(
				io::ErrorKind::InvalidInput,
				"RTCDataChannel requires one bounded bare frame",
			)));
		}
		std::task::ready!(self.poll_flush(cx))?;
		Poll::Ready(self.0.socket.send(body))
	}
	fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
		std::task::ready!(ready(&self.0, cx))?;
		if self.0.socket.buffered() > WEBRTC_DATA_CHANNEL_QUEUE_BYTES {
			Poll::Pending // the installed bufferedamountlow callback wakes writer
		} else {
			Poll::Ready(Ok(()))
		}
	}
}

pub(super) struct Closer {
	shared: Rc<Shared>,
	events: Option<Events>,
	deadline: Option<TimeoutFuture>,
}
impl Closer {
	pub(super) fn new(shared: Rc<Shared>) -> Self {
		let events = Some(Events::install(&shared));
		Self {
			shared,
			events,
			deadline: None,
		}
	}
	fn detach(&mut self) {
		if let Some(events) = self.events.take() {
			events.detach(&self.shared.socket);
		}
		self.deadline = None;
	}
}
impl ChannelClose for Closer {
	fn poll_close(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
		self.shared.request_close();
		if self.shared.state.borrow().closed {
			self.detach();
			return Poll::Ready(self.shared.state.borrow().result());
		}
		self.shared.state.borrow_mut().closer = Some(cx.waker().clone());
		let deadline = self
			.deadline
			.get_or_insert_with(|| TimeoutFuture::new(BINDING_BROWSER_CHANNEL_CLOSE_TIMEOUT_MS as u32));
		std::task::ready!(Pin::new(deadline).poll(cx));
		self.shared
			.fail(io::ErrorKind::TimedOut, "browser channel physical close timed out");
		self.shared.state.borrow_mut().closed = true;
		self.detach();
		Poll::Ready(self.shared.state.borrow().result())
	}
}
impl Drop for Closer {
	fn drop(&mut self) {
		self.shared.request_close();
		self.detach();
	}
}
