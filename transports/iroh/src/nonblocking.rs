//! The non-blocking scale surface (ADR-0019): per-connection buffered
//! reader/writer tasks, the endpoint readiness queue they signal, and the
//! try-read/try-write/try-accept calls the completion loop drives.

use super::*;

/// Non-blocking state for one connection: the bounded inbound/outbound buffers
/// the reader and writer tasks move bytes through, the notifies that wake those
/// tasks, and the endpoint readiness this connection signals into. The reader
/// and writer tasks own the QUIC streams (moved out of `GlowcapIrohConn`), so
/// they can hold them across `.await` without a `!Send` guard.
pub(crate) struct NbConn {
	readiness: Arc<Readiness>,
	/// Stable endpoint-scoped identity the loop matches drained records against.
	id: usize,
	inbound: Mutex<Inbound>,
	pub(crate) outbound: Mutex<Outbound>,
	/// Woken when the loop drains the inbound buffer: the reader parks here when
	/// the inbound buffer is at its bound and resumes when room frees.
	read_room: Notify,
	/// Woken when the loop enqueues outbound bytes or closes the connection: the
	/// writer parks here when the outbound buffer is empty.
	pub(crate) write_work: Notify,
	/// Wakes a writer already suspended inside QUIC flow control so its graceful
	/// drain acquires a deadline without making `conn_free` wait.
	pub(crate) close_work: Notify,
}

/// The inbound bytes as the Zig side treats them: one contiguous buffer with a
/// consumed prefix, `buf[off..]` unread. The reader appends whole QUIC chunks
/// with a memcpy. `conn_try_read` drains by advancing `off`. Draining to empty
/// resets the buffer and frees burst capacity past `NB_STEADY_BYTES`. A partial
/// drain compacts once the consumed prefix reaches the pending bytes, so the
/// buffer tracks the bounded pending count, never the total bytes ever
/// received.
#[derive(Default)]
pub(crate) struct Inbound {
	pub(crate) buf: Vec<u8>,
	/// Length of the consumed prefix of `buf`. `buf.len() - off` bytes pend.
	off: usize,
	/// Set once the QUIC recv stream reaches clean end of stream.
	eof: bool,
	/// Set once the reader task hit a transport error.
	err: bool,
}

impl Inbound {
	pub(crate) fn pending(&self) -> usize {
		self.buf.len() - self.off
	}

	pub(crate) fn read_budget(&self) -> usize {
		NB_BUFFER_BOUND.saturating_sub(self.pending()).min(READ_CHUNK_BYTES)
	}
}

#[derive(Default)]
pub(crate) struct Outbound {
	/// Bytes queued behind the writer's current batch.
	pub(crate) buf: Vec<u8>,
	/// Cleared allocation returned by the writer for the next batch. Keeping one
	/// steady-sized spare removes allocation churn without retaining a burst.
	pub(crate) spare: Vec<u8>,
	/// Bytes currently borrowed by the QUIC write future. Queue admission counts
	/// these too, so staging plus in-flight work share one `NB_BUFFER_BOUND`.
	pub(crate) in_flight: usize,
	/// Set by `conn_close` / `conn_free`: the writer finishes the send stream
	/// and exits once the buffer drains.
	pub(crate) closed: bool,
}

impl Outbound {
	pub(crate) fn pending(&self) -> usize {
		self.buf.len() + self.in_flight
	}

	pub(crate) fn take_batch(&mut self) -> Vec<u8> {
		debug_assert_eq!(self.in_flight, 0);
		let mut batch = std::mem::take(&mut self.spare);
		std::mem::swap(&mut batch, &mut self.buf);
		self.in_flight = batch.len();
		batch
	}

	/// Retire the writer's borrowed batch and report whether the application had
	/// closed the connection by the time the write completed. The writer must
	/// classify a failed write from this completion-time state: `conn_close` can
	/// set `closed` while QUIC flow control has the batch suspended.
	pub(crate) fn finish_batch(&mut self, mut batch: Vec<u8>, succeeded: bool) -> bool {
		debug_assert_eq!(self.in_flight, batch.len());
		let closed_before_completion = self.closed;
		self.in_flight = 0;
		if !succeeded {
			self.closed = true;
		}
		batch.clear();
		if batch.capacity() > NB_STEADY_BYTES {
			batch.shrink_to(NB_STEADY_BYTES);
		}
		self.spare = batch;
		closed_before_completion
	}
}

pub(crate) fn enqueue_outbound(out: &mut Outbound, src: &[u8]) -> isize {
	if out.closed {
		return -1;
	}
	if src.is_empty() {
		return 0;
	}
	let room = NB_BUFFER_BOUND.saturating_sub(out.pending());
	if room == 0 {
		return WOULD_BLOCK;
	}
	let accepted = room.min(src.len());
	out.buf.extend_from_slice(&src[..accepted]);
	accepted as isize
}

/// Get or lazily create this endpoint's readiness channel. Returns `None` only
/// if the self-pipe could not be created.
pub(crate) fn endpoint_readiness(ep: &GlowcapIrohEndpoint) -> Option<&Arc<Readiness>> {
	if ep.readiness.get().is_none()
		&& let Some(r) = Readiness::new()
	{
		let _ = ep.readiness.set(r);
	}
	ep.readiness.get()
}

/// The reader half of one non-blocking connection: drain the QUIC recv stream
/// into the bounded inbound buffer, signalling `EV_READABLE` as bytes land and
/// `EV_CLOSED` at end of stream or on error. Parks on `read_room` when the
/// buffer is full so a slow loop applies QUIC flow control to the partner.
async fn nb_reader(nb: Arc<NbConn>, mut recv: RecvStream) {
	use iroh::endpoint::{ConnectionError, ReadError};
	loop {
		// Back-pressure: wait while the inbound buffer is at its bound, then ask
		// QUIC for no more than the exact remaining budget. Register the notify
		// before re-checking so a drain that frees room cannot be missed between
		// the check and the await.
		let read_budget = loop {
			let notified = nb.read_room.notified();
			let budget = nb.inbound.lock().unwrap().read_budget();
			if budget > 0 {
				break budget;
			}
			notified.await;
		};
		// `read_chunk` lends the next segment zero-copy out of the stream's
		// reassembly buffer, so this task holds no resident scratch.
		// The one copy is the append into the connection's inbound buffer.
		match recv.read_chunk(read_budget).await {
			Ok(Some(chunk)) => {
				nb.inbound.lock().unwrap().buf.extend_from_slice(&chunk);
				nb.readiness.signal(nb.id, EV_READABLE);
			}
			Ok(None) => {
				nb.inbound.lock().unwrap().eof = true;
				nb.readiness.signal(nb.id, EV_READABLE | EV_CLOSED);
				break;
			}
			// A clean connection-level close is end of stream, not a fault.
			Err(ReadError::ConnectionLost(ConnectionError::ApplicationClosed(_)))
			| Err(ReadError::ConnectionLost(ConnectionError::LocallyClosed)) => {
				nb.inbound.lock().unwrap().eof = true;
				nb.readiness.signal(nb.id, EV_READABLE | EV_CLOSED);
				break;
			}
			Err(_) => {
				nb.inbound.lock().unwrap().err = true;
				nb.readiness.signal(nb.id, EV_CLOSED);
				break;
			}
		}
	}
}

/// The writer half of one non-blocking connection: drain the bounded outbound
/// buffer to the QUIC send stream, signalling `EV_WRITABLE` once a batch flushes.
/// Parks on `write_work` when the buffer is empty. Finishes the stream and exits
/// once the loop has closed the connection and the buffer has drained.
async fn nb_writer(nb: Arc<NbConn>, mut send: SendStream) -> Result<(), ()> {
	let mut close_deadline = None;
	loop {
		let notified = nb.write_work.notified();
		let (chunk, closed) = {
			let mut out = nb.outbound.lock().unwrap();
			// Swap the whole batch with the spare allocation: no copy, and the
			// lock is released before QUIC flow control can suspend this task.
			let chunk = out.take_batch();
			(chunk, out.closed)
		};
		if closed && close_deadline.is_none() {
			close_deadline = Some(tokio::time::Instant::now() + CLOSE_DRAIN_TIMEOUT);
		}
		if !chunk.is_empty() {
			let outcome = {
				let write = send.write_all(&chunk);
				tokio::pin!(write);
				if let Some(deadline) = close_deadline {
					tokio::time::timeout_at(deadline, &mut write).await.ok()
				} else {
					tokio::select! {
						result = &mut write => Some(result),
						_ = nb.close_work.notified() => {
							let deadline = tokio::time::Instant::now() + CLOSE_DRAIN_TIMEOUT;
							close_deadline = Some(deadline);
							tokio::time::timeout_at(deadline, &mut write).await.ok()
						}
					}
				}
			};
			let succeeded = outcome.as_ref().is_some_and(|result| result.is_ok());
			let clean_close = matches!(
				outcome,
				Some(Err(iroh::endpoint::WriteError::Stopped(_)
					| iroh::endpoint::WriteError::ConnectionLost(
						ConnectionError::ApplicationClosed(_) | ConnectionError::LocallyClosed
					)))
			);
			let closed_before_completion = nb.outbound.lock().unwrap().finish_batch(chunk, succeeded);
			if !succeeded {
				nb.readiness.signal(nb.id, EV_CLOSED);
				// Match the reader's connection-close classification. The writer
				// can observe the peer's close, or its stop of this stream (its
				// reader abort at connection release), before the application
				// observes EV_CLOSED and closes its handle. That scheduling order
				// must not turn a normal departure into a later endpoint release
				// failure. Other live-write failures still fail the drain barrier;
				// a local close retains its bounded best-effort farewell behavior.
				return if clean_close || closed_before_completion {
					Ok(())
				} else {
					Err(())
				};
			}
			nb.readiness.signal(nb.id, EV_WRITABLE);
			continue;
		}
		if closed {
			send.finish().map_err(|_| ())?;
			// finish queues FIN; it does not acknowledge the final bytes. The
			// stream holds the last connection reference after conn_free, so
			// dropping it here would implicitly close QUIC and discard the tail.
			let deadline = close_deadline.expect("closed writer has a drain deadline");
			return match tokio::time::timeout_at(deadline, send.stopped()).await {
				Ok(Ok(_)) => Ok(()),
				Ok(Err(iroh::endpoint::StoppedError::ConnectionLost(
					ConnectionError::ApplicationClosed(_) | ConnectionError::LocallyClosed,
				))) => Ok(()),
				_ => Err(()),
			};
		}
		notified.await;
	}
}

/// The acceptor of one endpoint's scale surface: pull incoming connections off
/// the wire into the ready queue and signal `EV_ACCEPT`, so the loop claims them
/// with `endpoint_try_accept` instead of parking a thread in a blocking accept.
async fn nb_acceptor(ep: Endpoint, connect_timeout: std::time::Duration, acc: Arc<AcceptState>) {
	loop {
		let Some(incoming) = ep.accept().await else {
			break;
		};
		let Some(generation) = acc.queue.lock().unwrap().generation() else {
			incoming.refuse();
			continue;
		};
		let Ok(accepting) = incoming.accept() else {
			continue;
		};
		let Ok(conn) = accepting.await else {
			continue;
		};
		// Same bound on the scale-path acceptor: a half-open dialer is dropped
		// after the timeout rather than stalling this loop's stream accept.
		let Ok(Ok((send, recv))) = tokio::time::timeout(connect_timeout, conn.accept_bi()).await else {
			continue;
		};
		acc.queue
			.lock()
			.unwrap()
			.push(generation, AcceptedRaw { conn, send, recv });
	}
}

pub(crate) mod calls;
