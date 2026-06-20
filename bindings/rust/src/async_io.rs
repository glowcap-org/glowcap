//! Opt-in async I/O over tokio (the `async` feature).
//!
//! The sync [`Peer`](crate::Peer) is sans-io — it never blocks and never owns a
//! socket. This module owns a tokio [`TcpStream`] and *drives* the peer over it:
//! read bytes, let the peer frame and dispatch them ([`Peer::recv_stream`]),
//! write the peer's outbound frames back, and surface events. One
//! [`AsyncConnection`] owns one peer, so it lives on one task (a connection
//! actor) — the peer is a single-owner state machine, never shared across
//! threads. The keyed handshake and the outbound pump are shared with the
//! [`Connection`](crate::Connection) driver in [`crate::wire`].

use crate::wire::{handshake, io_err, pump_outbound, READ_CHUNK};
use crate::{Argument, Event, Peer, Reference, Resolution, Result};
use tokio::io::AsyncReadExt;
use tokio::net::{TcpStream, ToSocketAddrs};

/// An OCapN/CapTP peer driven asynchronously over a tokio TCP stream. The async
/// convenience layer owns a library-allocator peer (`Peer<'static>`). This is
/// the pump layer [`Connection`](crate::Connection) builds on; an application
/// usually holds a `Connection`.
pub struct AsyncConnection {
	peer: Peer<'static>,
	stream: TcpStream,
	// Inbound bytes read from the wire but not yet framed into whole frames.
	inbox: Vec<u8>,
}

impl AsyncConnection {
	/// Connect to `addr` and complete the keyed OCapN handshake, signing the
	/// socket's own local address as the `tcp` locator.
	pub async fn connect<A: ToSocketAddrs>(addr: A) -> Result<AsyncConnection> {
		let mut stream = TcpStream::connect(addr).await.map_err(io_err)?;
		let designator = stream
			.local_addr()
			.map(|a| a.to_string())
			.unwrap_or_else(|_| "127.0.0.1:0".to_string());
		let mut peer = Peer::new()?;
		// The handshake threads this connection's own inbox: a partner may
		// pipeline bytes right behind its op:start-session, and those bytes
		// must stay buffered for `next_event` rather than be dropped.
		let mut inbox: Vec<u8> = Vec::new();
		let mut chunk = [0u8; READ_CHUNK];
		handshake(
			&mut peer,
			&mut stream,
			"tcp",
			&designator,
			&mut inbox,
			&mut chunk,
			None,
		)
		.await?;
		Ok(AsyncConnection {
			peer,
			stream,
			inbox,
		})
	}

	/// Wrap an already-connected stream and a peer you have configured
	/// (registered exports/imports, bootstrap caps, …).
	pub fn from_stream(peer: Peer<'static>, stream: TcpStream) -> AsyncConnection {
		AsyncConnection {
			peer,
			stream,
			inbox: Vec::new(),
		}
	}

	/// Borrow the owned peer, e.g. to register exports/imports before driving.
	pub fn peer(&mut self) -> &mut Peer<'static> {
		&mut self.peer
	}

	/// Queue a call to `target` and flush it to the wire. `answer` requests a reply.
	pub async fn send_deliver(
		&mut self,
		target: &Reference,
		args: &[Argument],
		answer: Option<u64>,
	) -> Result<()> {
		self.peer.send_deliver(target, args, answer)?;
		self.pump_outbound().await
	}

	/// Queue a reply settling `answer` and flush it to the wire.
	pub async fn send_resolve(&mut self, answer: u64, resolution: &Resolution) -> Result<()> {
		self.peer.send_resolve(answer, resolution)?;
		self.pump_outbound().await
	}

	/// Await the next application event, driving the socket as needed. Returns
	/// `Ok(None)` on a clean end of stream.
	pub async fn next_event(&mut self) -> Result<Option<Event>> {
		loop {
			// A surfaced event takes priority.
			if let Some(event) = self.peer.poll()? {
				return Ok(Some(event));
			}
			// Flush anything the last dispatch queued (replies, aborts). Stepping
			// to idle settles answers, which drains their pipelined calls and
			// projections into *fresh* events, so re-poll before blocking on the
			// wire, otherwise those drained events sit unseen until the partner
			// happens to send again, hanging a pipelined batch.
			self.pump_outbound().await?;
			if let Some(event) = self.peer.poll()? {
				return Ok(Some(event));
			}
			// Consume every whole frame already buffered; each may surface an
			// event or queue outbound, so loop back to re-check.
			if self.consume_buffered()? {
				continue;
			}
			// Need more bytes from the wire.
			let mut chunk = [0u8; READ_CHUNK];
			let n = self.stream.read(&mut chunk).await.map_err(io_err)?;
			if n == 0 {
				return Ok(None); // clean EOF
			}
			self.inbox.extend_from_slice(&chunk[..n]);
		}
	}

	// Dispatch one buffered frame if a whole one is present. Returns true when a
	// frame was consumed (loop again), false when more bytes are needed.
	fn consume_buffered(&mut self) -> Result<bool> {
		match self.peer.recv_stream(&self.inbox)? {
			Some(consumed) => {
				self.inbox.drain(..consumed);
				Ok(true)
			}
			None => Ok(false),
		}
	}

	// Encode pending outbound work and write every queued frame to the socket.
	async fn pump_outbound(&mut self) -> Result<()> {
		pump_outbound(&mut self.peer, &mut self.stream).await
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use tokio::io::AsyncWriteExt;
	use tokio::net::TcpListener;
	use tokio::sync::oneshot;

	// The handshake must keep bytes a partner pipelines right behind its
	// session-opening frame: the responder writes its op:start-session and the
	// head of a first deliver in one TCP write, so the deliver's opening bytes
	// land in the same read as the handshake frame. `connect` threads the
	// connection's own inbox through the handshake, so the tail completes the
	// frame and the deliver surfaces; dropping those bytes would desync stream
	// framing for the whole session.
	#[tokio::test]
	async fn connect_keeps_bytes_coalesced_behind_the_session_opening_frame() {
		let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
		let addr = listener.local_addr().unwrap();
		let (export_ready_tx, export_ready_rx) = oneshot::channel::<()>();

		let responder = async move {
			let (mut stream, _) = listener.accept().await.unwrap();
			let mut peer = Peer::new().unwrap();
			// Queue our start-session but write nothing yet, so the hello and
			// the deliver below can coalesce into one TCP write.
			peer.start_session(&[9u8; 32], "tcp", "127.0.0.1:9", true)
				.unwrap();
			let mut inbox: Vec<u8> = Vec::new();
			let mut chunk = [0u8; READ_CHUNK];
			while !peer.session_is_open() {
				let n = stream.read(&mut chunk).await.unwrap();
				assert!(n > 0, "the dialer closed during the handshake");
				inbox.extend_from_slice(&chunk[..n]);
				while let Some(consumed) = peer.recv_stream(&inbox).unwrap() {
					inbox.drain(..consumed);
				}
			}

			peer.register_import(7).unwrap();
			peer.send_deliver(&Reference::far(7), &[Argument::Integer(42)], None)
				.unwrap();
			// One step encodes the pending start-session; the deliver encodes
			// on the next.
			peer.step().unwrap();
			let hello = peer
				.take_outbound()
				.unwrap()
				.expect("the start-session frame");
			peer.step().unwrap();
			let deliver = peer.take_outbound().unwrap().expect("the deliver frame");

			// One TCP write: the whole hello plus the deliver's head.
			let split = deliver.len() / 2;
			let mut coalesced = hello;
			coalesced.extend_from_slice(&deliver[..split]);
			stream.write_all(&coalesced).await.unwrap();
			stream.flush().await.unwrap();

			// Hold the tail until the dialer has registered export 7, so the
			// deliver cannot complete before its target exists.
			export_ready_rx.await.unwrap();
			stream.write_all(&deliver[split..]).await.unwrap();
			stream.flush().await.unwrap();
			stream // keep the socket open until both halves finish
		};

		let dialer = async {
			let mut conn = AsyncConnection::connect(addr).await.unwrap();
			conn.peer().register_export(7).unwrap();
			export_ready_tx.send(()).unwrap();
			// The partner's start-session also surfaces (as an Other event);
			// the pipelined deliver must follow it intact.
			loop {
				match conn
					.next_event()
					.await
					.unwrap()
					.expect("the pipelined deliver")
				{
					Event::Deliver {
						target,
						args,
						answer,
					} => {
						assert_eq!(
							target,
							Reference::Near {
								id: 7,
								promise: false
							}
						);
						assert_eq!(args, vec![Argument::Integer(42)]);
						assert_eq!(answer, None);
						break;
					}
					Event::Other { .. } => continue,
					other => panic!("expected the pipelined deliver, got {other:?}"),
				}
			}
		};

		let (_stream, ()) = tokio::join!(responder, dialer);
	}
}
