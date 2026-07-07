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

/// Map a transport `std::io::Error` to a pancake [`Error`], carrying the
/// original message through the detail channel so a consumer can tell
/// connection-refused from timeout from reset (the public `Error` keeps its
/// `Clone`/`PartialEq` derives, so it holds the message string, not a
/// `Box<dyn Error>` source). The flat code stays `PANCAKE_ERR_IO`.
pub(crate) fn io_err(e: std::io::Error) -> Error {
	Error::with_detail(sys::ERR_IO, e.to_string())
}

/// Encode every pending outbound message and write the queued frames, then
/// flush. Generic over the byte sink so the same pump drives a peer over TCP or
/// over the iroh sidecar bridge; the frame unit is identical. Stepping to idle
/// (not once) is what keeps a pipelined batch whole: a projection's settlement
/// cascades — a resolve drains the projection, whose resolve fires a listener
/// that queues a deliver — and each link is a separate step. A single step would
/// strand the tail in the queue, deadlocking a partner parked on the answer it
/// carries.
pub(crate) async fn pump_outbound<S: AsyncWrite + Unpin>(
	peer: &mut Peer<'_>,
	stream: &mut S,
) -> Result<()> {
	peer.step_to_idle()?;
	while let Some(frame) = peer.take_outbound()? {
		stream.write_all(&frame).await.map_err(io_err)?;
	}
	stream.flush().await.map_err(io_err)?;
	Ok(())
}

/// Complete the keyed `op:start-session` handshake: sign `transport`/`designator`
/// with a session seed, flush it, and read until the partner's start-session
/// opens the session. Pass `seed: None` to mint a per-connection random seed
/// (entropy at the I/O boundary, never in the sans-io core); pass `Some(seed)` to
/// reuse a retained identity — the recipient half of a three-party handoff dials
/// the exporter with the same seed it presented to the gifter, which is what the
/// exporter verifies the `desc:handoff-receive` against. Returns the seed
/// actually used so the caller can retain it for later exporter dials. The caller
/// names the locator — its own `host:port` for a `tcp` dialer (a true locator a
/// Goblins partner accepts), an empty designator for an iroh dialer whose
/// identity is the session key, the local endpoint id for an iroh listener.
/// Leftover inbound bytes stay in `inbox` for the caller's main loop. The
/// exchange is symmetric — both ends send first, then read — so two pancake peers
/// (or pancake and Goblins) converge.
pub(crate) async fn handshake<S: AsyncRead + AsyncWrite + Unpin>(
	peer: &mut Peer<'_>,
	stream: &mut S,
	transport: &str,
	designator: &str,
	inbox: &mut Vec<u8>,
	chunk: &mut [u8],
	seed: Option<[u8; 32]>,
) -> Result<[u8; 32]> {
	let seed = match seed {
		Some(seed) => seed,
		None => {
			let mut seed = [0u8; 32];
			getrandom::getrandom(&mut seed).map_err(|_| Error::from_code(sys::ERR_INTERNAL))?;
			seed
		}
	};
	peer.start_session(&seed, transport, designator, true)?;
	pump_outbound(peer, stream).await?;
	while !peer.session_is_open() {
		let n = stream.read(&mut *chunk).await.map_err(io_err)?;
		if n == 0 {
			return Err(Error::from_code(sys::ERR_CLOSED)); // closed during the handshake
		}
		inbox.extend_from_slice(&chunk[..n]);
		// Ingest only up to the frame that opens the session. A partner may
		// pipeline application frames — most sharply, a bootstrap fetch — right
		// behind its start-session; those must not be dispatched here, because a
		// fetch is answered the instant it is ingested (the responder is
		// automatic) and the host has not yet published its bootstrap caps. They
		// stay in `inbox` for the caller's main loop, which dispatches them only
		// after applying the host's setup (publish), the ordering the Zig
		// LoopHost guarantees by publishing in connection setup.
		while !peer.session_is_open() {
			match peer.recv_stream(inbox)? {
				Some(consumed) => {
					inbox.drain(..consumed);
				}
				None => break,
			}
		}
		pump_outbound(peer, stream).await?;
	}
	Ok(seed)
}
