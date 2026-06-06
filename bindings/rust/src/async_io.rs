//! Opt-in async I/O over tokio (the `async` feature).
//!
//! The sync [`Peer`](crate::Peer) is sans-io — it never blocks and never owns a
//! socket. This module owns a tokio [`TcpStream`] and *drives* the peer over it:
//! read bytes, let the peer frame and dispatch them ([`Peer::recv_stream`]),
//! write the peer's outbound frames back, and surface events. One
//! [`AsyncConnection`] owns one peer, so it lives on one task (a connection
//! actor) — the peer is a single-owner state machine, never shared across
//! threads.

use crate::{Argument, Error, Event, Peer, Reference, Resolution, Result};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpStream, ToSocketAddrs};

const READ_CHUNK: usize = 16 * 1024;

/// An OCapN/CapTP peer driven asynchronously over a tokio TCP stream.
pub struct AsyncConnection {
    peer: Peer,
    stream: TcpStream,
    // Inbound bytes read from the wire but not yet framed into whole frames.
    inbox: Vec<u8>,
}

impl AsyncConnection {
    /// Connect to `addr` and wrap a fresh peer driven over the connection.
    pub async fn connect<A: ToSocketAddrs>(addr: A) -> Result<AsyncConnection> {
        let stream = TcpStream::connect(addr).await.map_err(io_err)?;
        Ok(AsyncConnection::from_stream(Peer::new()?, stream))
    }

    /// Wrap an already-connected stream and a peer you have configured
    /// (registered exports/imports, bootstrap caps, …).
    pub fn from_stream(peer: Peer, stream: TcpStream) -> AsyncConnection {
        AsyncConnection { peer, stream, inbox: Vec::new() }
    }

    /// Borrow the owned peer — e.g. to register exports/imports before driving.
    pub fn peer(&mut self) -> &mut Peer {
        &mut self.peer
    }

    /// Queue a call to `target` and flush it to the wire. `answer` requests a reply.
    pub async fn send_deliver(&mut self, target: &Reference, args: &[Argument], answer: Option<u64>) -> Result<()> {
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
            if let Some(event) = self.peer.poll() {
                return Ok(Some(event));
            }
            // Flush anything the last dispatch queued (replies, aborts).
            self.pump_outbound().await?;
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
        self.peer.step()?;
        while let Some(frame) = self.peer.take_outbound() {
            self.stream.write_all(&frame).await.map_err(io_err)?;
        }
        self.stream.flush().await.map_err(io_err)?;
        Ok(())
    }
}

fn io_err(_: std::io::Error) -> Error {
    Error(-9) // PANCAKE_ERR_IO
}
