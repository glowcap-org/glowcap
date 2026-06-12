//! Socket driving shared by the async surfaces (the `async` feature).
//!
//! [`AsyncConnection`](crate::AsyncConnection) and the
//! [`Connection`](crate::Connection) driver task ride the same sans-io peer
//! over a byte stream, so the two primitives they share live here once: the
//! outbound pump (encode pending work, write every queued frame, flush) and
//! the keyed `op:start-session` handshake. Both are generic over the stream so
//! the identical drive carries a peer over TCP or over the iroh sidecar bridge
//! ([`crate::iroh::IrohStream`]) — the frame unit and the pump are the same;
//! only the transport moving the bytes differs. The handshake threads the
//! caller's inbox so bytes a partner pipelines right behind its
//! session-opening frame stay buffered for the caller's main loop — dropping
//! them would desync stream framing for the rest of the session.

use crate::{sys, Error, Peer, Result};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub(crate) const READ_CHUNK: usize = 16 * 1024;

pub(crate) fn io_err(_: std::io::Error) -> Error {
    Error::from_code(sys::ERR_IO)
}

/// Encode pending outbound work and write every queued frame, then flush. Generic
/// over the byte sink so the same pump drives a peer over TCP or over the iroh
/// sidecar bridge; the frame unit is identical.
pub(crate) async fn pump_outbound<S: AsyncWrite + Unpin>(peer: &mut Peer<'_>, stream: &mut S) -> Result<()> {
    peer.step()?;
    while let Some(frame) = peer.take_outbound()? {
        stream.write_all(&frame).await.map_err(io_err)?;
    }
    stream.flush().await.map_err(io_err)?;
    Ok(())
}

/// Complete the keyed `op:start-session` handshake: sign `transport`/`designator`
/// with a per-connection random session seed (entropy at the I/O boundary, never
/// in the sans-io core), flush it, and read until the partner's start-session
/// opens the session. The caller names the locator — its own `host:port` for a
/// `tcp` dialer (a true locator a Goblins partner accepts), an empty designator
/// for an iroh dialer whose identity is the session key, the local endpoint id
/// for an iroh listener. Leftover inbound bytes stay in `inbox` for the caller's
/// main loop. The exchange is symmetric — both ends send first, then read — so
/// two pancake peers (or pancake and Goblins) converge.
pub(crate) async fn handshake<S: AsyncRead + AsyncWrite + Unpin>(
    peer: &mut Peer<'_>,
    stream: &mut S,
    transport: &str,
    designator: &str,
    inbox: &mut Vec<u8>,
    chunk: &mut [u8],
) -> Result<()> {
    let mut seed = [0u8; 32];
    getrandom::getrandom(&mut seed).map_err(|_| Error::from_code(sys::ERR_INTERNAL))?;
    peer.start_session(&seed, transport, designator, true)?;
    pump_outbound(peer, stream).await?;
    while !peer.session_is_open() {
        let n = stream.read(&mut *chunk).await.map_err(io_err)?;
        if n == 0 {
            return Err(Error::from_code(sys::ERR_CLOSED)); // closed during the handshake
        }
        inbox.extend_from_slice(&chunk[..n]);
        while let Some(consumed) = peer.recv_stream(inbox)? {
            inbox.drain(..consumed);
        }
        pump_outbound(peer, stream).await?;
    }
    Ok(())
}
