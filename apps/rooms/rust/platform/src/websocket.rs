//! A WebSocket as a byte channel: each binary message is a run of stream
//! bytes, in order, and each write goes out as one binary message. That is
//! all a CapTP session or an opaque byte relay needs from its socket.
use futures_util::{Sink, Stream};
use std::{
	cell::RefCell,
	future::Future,
	io,
	pin::Pin,
	rc::Rc,
	task::{Context, Poll},
	time::Duration,
};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio_tungstenite::{WebSocketStream, tungstenite::Message};

pub struct WsBytes<S> {
	inner: Rc<RefCell<Inner<S>>>,
}

struct Inner<S> {
	ws: WebSocketStream<S>,
	pending: bytes::Bytes,
	at: usize,
	ended: bool,
	close: CloseState,
	retired: bool,
	remaining: usize,
	liveness: Option<Liveness>,
}

enum CloseState {
	Open,
	/// An explicit protocol close intent that has not reached the socket yet.
	/// Keeping it in shared state makes cancellation before the next poll safe.
	Pending(Option<tokio_tungstenite::tungstenite::protocol::CloseFrame>),
	Sent,
}

impl<S> Clone for WsBytes<S> {
	fn clone(&self) -> Self {
		Self {
			inner: self.inner.clone(),
		}
	}
}

impl<S: AsyncRead + AsyncWrite + Unpin> WsBytes<S> {
	/// The owning adapter supplies a protocol close reason after its operation
	/// finishes. A received close already owns the reply and is only flushed.
	pub async fn close(
		&mut self,
		frame: Option<tokio_tungstenite::tungstenite::protocol::CloseFrame>,
	) -> io::Result<()> {
		{
			let mut inner = self.inner.borrow_mut();
			if !inner.ended && matches!(inner.close, CloseState::Open) {
				inner.close = CloseState::Pending(frame);
			}
		}
		tokio::io::AsyncWriteExt::shutdown(self).await
	}

	/// Transfer this WebSocket into a byte-stream channel with an explicit
	/// protocol-retirement owner. The read and write halves stop application
	/// I/O; the retained closer sends or answers Close, waits for its peer, and
	/// only then retires the underlying stream.
	pub fn into_channel(self) -> glowcap::Channel
	where
		S: 'static,
	{
		let (reader, writer) = tokio::io::split(self.clone());
		glowcap::Channel::byte_stream(reader, writer, WsClose(self))
	}
}
struct Liveness {
	idle: Duration,
	last_received: tokio::time::Instant,
	pulse: Pin<Box<tokio::time::Sleep>>,
}

impl<S> WsBytes<S> {
	pub fn new(ws: WebSocketStream<S>) -> Self {
		Self {
			inner: Rc::new(RefCell::new(Inner {
				ws,
				pending: bytes::Bytes::new(),
				at: 0,
				ended: false,
				close: CloseState::Open,
				retired: false,
				remaining: usize::MAX,
				liveness: None,
			})),
		}
	}
	pub fn bounded(self, bytes: usize, idle: Duration) -> Self {
		let mut inner = self.inner.borrow_mut();
		inner.remaining = bytes;
		inner.liveness = Some(Liveness {
			idle,
			last_received: tokio::time::Instant::now(),
			pulse: Box::pin(tokio::time::sleep(idle / 2)),
		});
		drop(inner);
		self
	}
}

impl<S: AsyncRead + AsyncWrite + Unpin> AsyncRead for WsBytes<S> {
	fn poll_read(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
		let shared = self.get_mut();
		let mut inner = shared.inner.borrow_mut();
		let this = &mut *inner;
		loop {
			if this.ended {
				return Poll::Ready(Ok(()));
			}
			if let Some(liveness) = &mut this.liveness
				&& liveness.pulse.as_mut().poll(cx).is_ready()
			{
				if liveness.last_received.elapsed() >= liveness.idle {
					return Poll::Ready(Err(io::Error::new(
						io::ErrorKind::TimedOut,
						"WebSocket peer stopped answering",
					)));
				}
				match Pin::new(&mut this.ws).poll_ready(cx) {
					Poll::Pending => {}
					Poll::Ready(Err(error)) => return Poll::Ready(Err(io::Error::other(error))),
					Poll::Ready(Ok(())) => {
						Pin::new(&mut this.ws)
							.start_send(Message::Ping(bytes::Bytes::new()))
							.map_err(io::Error::other)?;
						liveness
							.pulse
							.as_mut()
							.reset(tokio::time::Instant::now() + liveness.idle / 2);
					}
				}
			}
			// Reading control frames may queue a protocol reply. Flush it even
			// when the application has no outbound bytes of its own.
			match Pin::new(&mut this.ws).poll_flush(cx) {
				Poll::Pending => {}
				Poll::Ready(Err(error)) => return Poll::Ready(Err(io::Error::other(error))),
				Poll::Ready(Ok(())) => {}
			}
			if this.at < this.pending.len() {
				let take = (this.pending.len() - this.at).min(buf.remaining());
				if take > this.remaining {
					return Poll::Ready(Err(io::Error::other("WebSocket byte budget exceeded")));
				}
				this.remaining -= take;
				buf.put_slice(&this.pending[this.at..this.at + take]);
				this.at += take;
				return Poll::Ready(Ok(()));
			}
			if this.ended {
				return Poll::Ready(Ok(()));
			}
			match Pin::new(&mut this.ws).poll_next(cx) {
				Poll::Pending => return Poll::Pending,
				Poll::Ready(Some(Ok(Message::Binary(bytes)))) => {
					if let Some(liveness) = &mut this.liveness {
						liveness.last_received = tokio::time::Instant::now();
					}
					this.pending = bytes;
					this.at = 0;
				}
				Poll::Ready(Some(Ok(Message::Text(text)))) => {
					if let Some(liveness) = &mut this.liveness {
						liveness.last_received = tokio::time::Instant::now();
					}
					this.pending = text.into();
					this.at = 0;
				}
				Poll::Ready(Some(Ok(Message::Ping(_) | Message::Pong(_) | Message::Frame(_)))) => {
					if let Some(liveness) = &mut this.liveness {
						liveness.last_received = tokio::time::Instant::now();
					}
					continue;
				}
				Poll::Ready(Some(Ok(Message::Close(_))) | None) => this.ended = true,
				Poll::Ready(Some(Err(error))) => return Poll::Ready(Err(io::Error::other(error))),
			}
		}
	}
}

impl<S: AsyncRead + AsyncWrite + Unpin> AsyncWrite for WsBytes<S> {
	/// One named copy per write: the caller lends `buf` for this call, while
	/// the WebSocket sink owns each message until it has gone out, so the
	/// bytes must be moved into a message the sink can keep. A pump driving
	/// this with `tokio::io::copy` pays it once per chunk in each direction.
	fn poll_write(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
		let shared = self.get_mut();
		let mut inner = shared.inner.borrow_mut();
		let this = &mut *inner;
		if buf.len() > this.remaining {
			return Poll::Ready(Err(io::Error::other("WebSocket byte budget exceeded")));
		}
		match Pin::new(&mut this.ws).poll_ready(cx) {
			Poll::Pending => return Poll::Pending,
			Poll::Ready(Err(error)) => return Poll::Ready(Err(io::Error::other(error))),
			Poll::Ready(Ok(())) => {}
		}
		Pin::new(&mut this.ws)
			.start_send(Message::Binary(buf.to_vec().into()))
			.map_err(io::Error::other)?;
		this.remaining -= buf.len();
		Poll::Ready(Ok(buf.len()))
	}
	fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
		let shared = self.get_mut();
		let mut inner = shared.inner.borrow_mut();
		Pin::new(&mut inner.ws).poll_flush(cx).map_err(io::Error::other)
	}
	fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
		let shared = self.get_mut();
		let mut inner = shared.inner.borrow_mut();
		let this = &mut *inner;
		if this.retired {
			return Poll::Ready(Ok(()));
		}
		// A received Close already queued its protocol reply. Starting a
		// second Close after that exchange is an illegal new write.
		let closed = if this.ended || matches!(this.close, CloseState::Sent) {
			Pin::new(&mut this.ws).poll_flush(cx)
		} else if matches!(this.close, CloseState::Open) {
			this.close = CloseState::Sent;
			Pin::new(&mut this.ws).poll_close(cx)
		} else {
			match Pin::new(&mut this.ws).poll_ready(cx) {
				Poll::Pending => return Poll::Pending,
				Poll::Ready(Err(error)) => return Poll::Ready(Err(io::Error::other(error))),
				Poll::Ready(Ok(())) => {}
			}
			let CloseState::Pending(frame) = std::mem::replace(&mut this.close, CloseState::Sent) else {
				unreachable!("pending close state was already classified")
			};
			if let Err(error) = Pin::new(&mut this.ws).start_send(Message::Close(frame)) {
				return Poll::Ready(Err(io::Error::other(error)));
			}
			Pin::new(&mut this.ws).poll_flush(cx)
		};
		match closed {
			Poll::Ready(Ok(()))
			| Poll::Ready(Err(
				tokio_tungstenite::tungstenite::Error::ConnectionClosed
				| tokio_tungstenite::tungstenite::Error::AlreadyClosed,
			)) => {
				// Sink::poll_close only flushes our Close. Keep the socket until
				// the peer's reply is read; dropping it with unread bytes can send
				// a TCP reset and turn an orderly browser close into code 1006.
				for _ in 0..32 {
					if this.ended {
						return match Pin::new(this.ws.get_mut()).poll_shutdown(cx) {
							Poll::Ready(Ok(())) => {
								this.retired = true;
								Poll::Ready(Ok(()))
							}
							other => other,
						};
					}
					match Pin::new(&mut this.ws).poll_next(cx) {
						Poll::Pending => return Poll::Pending,
						Poll::Ready(None | Some(Ok(Message::Close(_)))) => this.ended = true,
						Poll::Ready(Some(Ok(_))) => {}
						Poll::Ready(Some(Err(error))) => return Poll::Ready(Err(io::Error::other(error))),
					}
				}
				cx.waker().wake_by_ref();
				Poll::Pending
			}
			Poll::Ready(Err(error)) => Poll::Ready(Err(io::Error::other(error))),
			Poll::Pending => Poll::Pending,
		}
	}
}

struct WsClose<S>(WsBytes<S>);

impl<S: AsyncRead + AsyncWrite + Unpin> glowcap::ChannelClose for WsClose<S> {
	fn poll_close(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
		Pin::new(&mut self.0).poll_shutdown(cx)
	}
}

#[cfg(test)]
mod tests;
