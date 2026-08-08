//! The WebSocket byte stream for the keyed-relay rendezvous dial (ADR-0088).
//!
//! A `keyed-relay` peer holds an inbound socket at a relay under its key
//! designator; the dialer opens the relay's rendezvous leg and the keyed OCapN
//! handshake runs end to end over it. This module adapts one client WebSocket
//! (tokio-tungstenite) to the `AsyncRead + AsyncWrite` stream
//! [`crate::Session::establish_dialed_locator`] drives, the same seam the TCP
//! socket and [`crate::iroh::IrohStream`] fill.
//!
//! A WebSocket is message-framed while the session reads a byte stream, so
//! `poll_read` buffers the unconsumed tail of the last binary message across
//! calls — the impedance match `IrohStream` models for the sidecar's chunked
//! reads. `poll_write` sends each chunk as one binary message; the host's
//! stream delimiter owns framing above, exactly as over TCP.

use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};

use futures_util::{Sink, Stream};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{connect_async_with_config, MaybeTlsStream, WebSocketStream};

use crate::{sys, Error, Result};

/// Open a WebSocket to `url` and adapt it. A failure before the upgrade
/// completes is a typed dial error; after it, an error or close surfaces
/// through the stream, which the session's teardown classifies.
/// The per-connection WebSocket buffers, named rather than inherited.
///
/// tungstenite 0.25 gave `read_buffer_size` a 128 KiB default, and its changelog
/// warns that the new default costs memory wherever a process holds many
/// connections. A client holds one per rendezvous leg, so the cost is smaller
/// here than in the relay, but an unnamed per-connection buffer is the thing
/// this project's memory posture forbids either way. The write buffer has
/// defaulted to 128 KiB since 0.20 and is named alongside it.
///
/// 16 KiB per direction matches `steady_outbound_bytes` on the Zig side, so the
/// binding and the sessions it carries answer to one number.
const WS_BUFFER_BYTES: usize = 16 * 1024;

pub(crate) async fn connect_websocket(url: &str) -> Result<WsStream> {
	let config = WebSocketConfig::default()
		.read_buffer_size(WS_BUFFER_BYTES)
		.write_buffer_size(WS_BUFFER_BYTES);
	let (inner, _response) = connect_async_with_config(url, Some(config), false)
		.await
		.map_err(|e| {
			Error::with_detail(
				sys::ERR_INVALID_ARGUMENT,
				format!("rendezvous WebSocket connect failed: {e}"),
			)
		})?;
	Ok(WsStream {
		inner,
		read_buf: Vec::new(),
		read_pos: 0,
	})
}

/// One client WebSocket as a byte stream (see the module header).
pub(crate) struct WsStream {
	inner: WebSocketStream<MaybeTlsStream<TcpStream>>,
	// The unconsumed tail of the last binary message, handed out across
	// `poll_read` calls; drained before the next message is pulled.
	read_buf: Vec<u8>,
	read_pos: usize,
}

fn ws_io_err(e: tokio_tungstenite::tungstenite::Error) -> io::Error {
	io::Error::other(e)
}

impl AsyncRead for WsStream {
	fn poll_read(
		self: Pin<&mut Self>,
		cx: &mut Context<'_>,
		buf: &mut ReadBuf<'_>,
	) -> Poll<io::Result<()>> {
		let this = self.get_mut();
		loop {
			if this.read_pos < this.read_buf.len() {
				let tail = &this.read_buf[this.read_pos..];
				let n = tail.len().min(buf.remaining());
				buf.put_slice(&tail[..n]);
				this.read_pos += n;
				if this.read_pos == this.read_buf.len() {
					this.read_buf.clear();
					this.read_pos = 0;
				}
				return Poll::Ready(Ok(()));
			}
			match Pin::new(&mut this.inner).poll_next(cx) {
				Poll::Ready(Some(Ok(Message::Binary(bytes)))) => {
					this.read_buf = bytes.into();
					this.read_pos = 0;
				}
				Poll::Ready(Some(Ok(Message::Text(text)))) => {
					this.read_buf = text.as_bytes().to_vec();
					this.read_pos = 0;
				}
				// Control frames carry no session bytes; tungstenite answers a
				// ping itself on the next flush.
				Poll::Ready(Some(Ok(_))) => continue,
				// A close frame or an ended stream is a clean end of stream.
				Poll::Ready(None) => return Poll::Ready(Ok(())),
				Poll::Ready(Some(Err(e))) => return Poll::Ready(Err(ws_io_err(e))),
				Poll::Pending => return Poll::Pending,
			}
		}
	}
}

impl AsyncWrite for WsStream {
	fn poll_write(
		self: Pin<&mut Self>,
		cx: &mut Context<'_>,
		buf: &[u8],
	) -> Poll<io::Result<usize>> {
		let this = self.get_mut();
		match Pin::new(&mut this.inner).poll_ready(cx) {
			Poll::Ready(Ok(())) => {}
			Poll::Ready(Err(e)) => return Poll::Ready(Err(ws_io_err(e))),
			Poll::Pending => return Poll::Pending,
		}
		match Pin::new(&mut this.inner).start_send(Message::binary(buf.to_vec())) {
			Ok(()) => Poll::Ready(Ok(buf.len())),
			Err(e) => Poll::Ready(Err(ws_io_err(e))),
		}
	}

	fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
		Pin::new(&mut self.get_mut().inner)
			.poll_flush(cx)
			.map_err(ws_io_err)
	}

	fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
		Pin::new(&mut self.get_mut().inner)
			.poll_close(cx)
			.map_err(ws_io_err)
	}
}
