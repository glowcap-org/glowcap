//! The non-blocking scale surface (ADR-0057): per-connection buffered
//! reader/writer tasks, the endpoint readiness queue they signal, and the
//! try-read/try-write/try-accept calls the completion loop drives.

use super::*;

/// Non-blocking state for one connection: the bounded inbound/outbound buffers
/// the reader and writer tasks move bytes through, the notifies that wake those
/// tasks, and the endpoint readiness this connection signals into. The reader
/// and writer tasks own the QUIC streams (moved out of `PancakeIrohConn`), so
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
/// with a memcpy; `conn_try_read` drains by advancing `off`. Draining to empty
/// resets the buffer and frees burst capacity past `NB_STEADY_BYTES`; a partial
/// drain compacts once the consumed prefix reaches the pending bytes, so the
/// buffer tracks the bounded pending count, never the total bytes ever
/// received.
#[derive(Default)]
pub(crate) struct Inbound {
	pub(crate) buf: Vec<u8>,
	/// Length of the consumed prefix of `buf`; `buf.len() - off` bytes pend.
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

	pub(crate) fn finish_batch(&mut self, mut batch: Vec<u8>, succeeded: bool) {
		debug_assert_eq!(self.in_flight, batch.len());
		self.in_flight = 0;
		if !succeeded {
			self.closed = true;
		}
		batch.clear();
		if batch.capacity() > NB_STEADY_BYTES {
			batch.shrink_to(NB_STEADY_BYTES);
		}
		self.spare = batch;
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
pub(crate) fn endpoint_readiness(ep: &PancakeIrohEndpoint) -> Option<&Arc<Readiness>> {
	if ep.readiness.get().is_none() {
		if let Some(r) = Readiness::new() {
			let _ = ep.readiness.set(r);
		}
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
		// reassembly buffer, so this task holds no resident scratch (the old
		// shape was a 64 KiB read buffer held for the connection's lifetime).
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
/// Parks on `write_work` when the buffer is empty; finishes the stream and exits
/// once the loop has closed the connection and the buffer has drained.
async fn nb_writer(nb: Arc<NbConn>, mut send: SendStream) -> Result<(), ()> {
	loop {
		let notified = nb.write_work.notified();
		let (chunk, closed) = {
			let mut out = nb.outbound.lock().unwrap();
			// Swap the whole batch with the spare allocation: no copy, and the
			// lock is released before QUIC flow control can suspend this task.
			let chunk = out.take_batch();
			(chunk, out.closed)
		};
		if !chunk.is_empty() {
			let succeeded = {
				let write = send.write_all(&chunk);
				tokio::pin!(write);
				tokio::select! {
					result = &mut write => result.is_ok(),
					_ = nb.close_work.notified() => {
						tokio::time::timeout(CLOSE_DRAIN_TIMEOUT, &mut write)
							.await
							.is_ok_and(|result| result.is_ok())
					}
				}
			};
			nb.outbound.lock().unwrap().finish_batch(chunk, succeeded);
			if !succeeded {
				nb.readiness.signal(nb.id, EV_CLOSED);
				return Err(());
			}
			nb.readiness.signal(nb.id, EV_WRITABLE);
			continue;
		}
		if closed {
			return send.finish().map_err(|_| ());
		}
		notified.await;
	}
}

/// The acceptor of one endpoint's scale surface: pull incoming connections off
/// the wire into the ready queue and signal `EV_ACCEPT`, so the loop claims them
/// with `endpoint_try_accept` instead of parking a thread in a blocking accept.
async fn nb_acceptor(
	ep: Endpoint,
	connect_timeout: std::time::Duration,
	acc: Arc<AcceptState>,
	readiness: Arc<Readiness>,
) {
	loop {
		let Some(incoming) = ep.accept().await else {
			break;
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
		let queued = {
			let mut ready = acc.ready.lock().unwrap();
			if ready.len() >= ACCEPT_QUEUE_BOUND {
				false
			} else {
				ready.push_back(AcceptedRaw { conn, send, recv });
				true
			}
		};
		if queued {
			readiness.signal(0, EV_ACCEPT);
		}
	}
}

/// The OS readiness fd for this endpoint's scale surface: the read end of the
/// self-pipe the sidecar nudges whenever a connection (or the acceptor) becomes
/// ready. The completion loop registers this once and polls it; on wake it
/// calls `pancake_iroh_sidecar_endpoint_drain_ready`, which clears the fd's
/// coalesced bytes before it drains records.
/// Returns -1 if the readiness channel could not be created. Borrows the handle;
/// the fd is owned by the endpoint and is valid until
/// `pancake_iroh_sidecar_endpoint_free`.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_endpoint_readiness_fd(ep: *const PancakeIrohEndpoint) -> i32 {
	let result = catch_unwind(AssertUnwindSafe(|| {
		let ep = unsafe { &*ep };
		match endpoint_readiness(ep) {
			Some(r) => r.reader.as_raw_fd(),
			None => -1,
		}
	}));
	result.unwrap_or(-1)
}

/// Drain pending readiness records into the caller's buffer. `out` points at
/// `out_cap` `PancakeIrohReadyEvent` records; the call writes up to that many and
/// returns the count (>= 0), or -1 on error. No allocation per call. If more
/// records remain queued than fit, the endpoint re-nudges its readiness fd so the
/// loop wakes again to drain the rest. Borrows the handle.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_endpoint_drain_ready(
	ep: *const PancakeIrohEndpoint,
	out: *mut PancakeIrohReadyEvent,
	out_cap: usize,
) -> isize {
	let result = catch_unwind(AssertUnwindSafe(|| {
		let ep = unsafe { &*ep };
		let r = match ep.readiness.get() {
			Some(r) => r,
			None => return 0,
		};
		if out.is_null() || out_cap == 0 {
			return 0;
		}
		let dest = unsafe { std::slice::from_raw_parts_mut(out, out_cap) };
		r.drain(dest) as isize
	}));
	result.unwrap_or(-1)
}

/// Start the non-blocking acceptor for this endpoint: incoming connections are
/// pulled off the wire and surfaced through `endpoint_try_accept` instead of the
/// blocking `accept`. Idempotent. Returns 0 on success, -1 if the readiness
/// channel could not be created. Borrows the handle.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_endpoint_set_nonblocking_accept(ep: *mut PancakeIrohEndpoint) -> i32 {
	let result = catch_unwind(AssertUnwindSafe(|| {
		let ep = unsafe { &*ep };
		if ep.accept.get().is_some() {
			return 0;
		}
		let readiness = match endpoint_readiness(ep) {
			Some(r) => r.clone(),
			None => return -1,
		};
		let acc = Arc::new(AcceptState {
			ready: Mutex::new(VecDeque::new()),
		});
		if ep.accept.set(acc.clone()).is_err() {
			return 0; // raced with another caller; theirs won
		}
		ep.rt
			.spawn(nb_acceptor(ep.ep.clone(), ep.connect_timeout, acc, readiness));
		0
	}));
	result.unwrap_or(-1)
}

/// Claim one connection the acceptor has pulled off the wire, or null when none
/// is waiting (the non-blocking counterpart of `accept`: null is `WOULD_BLOCK`,
/// not failure, the loop retries on the next `EV_ACCEPT`). The returned handle
/// is a fresh blocking connection; the loop calls `conn_set_nonblocking` on it
/// to bind it to the readiness surface. Returns an owned handle or null. The
/// endpoint must outlive the connection.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_endpoint_try_accept(ep: *mut PancakeIrohEndpoint) -> *mut PancakeIrohConn {
	let result = catch_unwind(AssertUnwindSafe(|| {
		let ep = unsafe { &*ep };
		let acc = ep.accept.get()?;
		let raw = acc.ready.lock().unwrap().pop_front()?;
		make_conn(ep, raw)
	}));
	match result {
		Ok(Some(handle)) => handle,
		_ => std::ptr::null_mut(),
	}
}

/// Move a connection onto the endpoint's readiness surface: the reader and
/// writer tasks take its streams, and from here `conn_try_read` / `conn_try_write`
/// replace the blocking `conn_read` / `conn_write`. Idempotent. Returns 0 on
/// success, -1 if the endpoint's readiness channel is unavailable or the streams
/// were already taken. `ep` must be the endpoint that minted `conn`. Borrows
/// both handles.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_conn_set_nonblocking(
	ep: *mut PancakeIrohEndpoint,
	conn: *mut PancakeIrohConn,
) -> i32 {
	let result = catch_unwind(AssertUnwindSafe(|| {
		let ep = unsafe { &*ep };
		let conn_ref = unsafe { &*conn };
		let _transition = conn_ref.nonblocking_transition.lock().unwrap();
		if conn_ref.nb.get().is_some() {
			return 0;
		}
		let readiness = match endpoint_readiness(ep) {
			Some(r) => r.clone(),
			None => return -1,
		};
		let send = conn_ref.send.lock().unwrap().take();
		let recv = conn_ref.recv.lock().unwrap().take();
		let (send, recv) = match (send, recv) {
			(Some(s), Some(r)) => (s, r),
			_ => return -1,
		};
		let nb = Arc::new(NbConn {
			readiness: readiness.clone(),
			id: conn_ref.id,
			inbound: Mutex::new(Inbound::default()),
			outbound: Mutex::new(Outbound::default()),
			read_room: Notify::new(),
			write_work: Notify::new(),
			close_work: Notify::new(),
		});
		if conn_ref.nb.set(nb.clone()).is_err() {
			unreachable!("transition lock owns the OnceLock");
		}
		let reader = ep.rt.spawn(nb_reader(nb.clone(), recv));
		let writer_permit = conn_ref.writers.acquire();
		let writer = ep.rt.spawn(async move {
			if nb_writer(nb, send).await.is_ok() {
				writer_permit.succeed();
			}
		});
		let _ = conn_ref.nb_tasks.set((reader, writer));
		// The connection starts writable: the loop may flush as soon as it has
		// bytes to send.
		readiness.signal(conn_ref.id, EV_WRITABLE);
		0
	}));
	result.unwrap_or(-1)
}

/// Stable readiness identity for a connection. It is unique for the endpoint's
/// lifetime and never derived from the allocation address.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_conn_id(conn: *const PancakeIrohConn) -> usize {
	let result = catch_unwind(AssertUnwindSafe(|| {
		if conn.is_null() {
			return 0;
		}
		unsafe { (*conn).id }
	}));
	result.unwrap_or(0)
}

/// Non-blocking read: copy up to `len` buffered inbound bytes into `buf`. Returns
/// the byte count (> 0), 0 at clean end of stream, -1 on error, or
/// `PANCAKE_IROH_WOULD_BLOCK` (-2) when no bytes are buffered yet. Draining the
/// buffer frees room for the reader task to resume. The connection must have been
/// moved to the readiness surface with `conn_set_nonblocking`. Borrows the handle.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_conn_try_read(conn: *mut PancakeIrohConn, buf: *mut u8, len: usize) -> isize {
	let result = catch_unwind(AssertUnwindSafe(|| {
		let conn = unsafe { &*conn };
		let nb = match conn.nb.get() {
			Some(nb) => nb,
			None => return -1,
		};
		let mut inb = nb.inbound.lock().unwrap();
		let pending = inb.pending();
		if pending > 0 {
			let n = std::cmp::min(len, pending);
			if n > 0 {
				let dest = unsafe { std::slice::from_raw_parts_mut(buf, n) };
				dest.copy_from_slice(&inb.buf[inb.off..inb.off + n]);
				inb.off += n;
			}
			if inb.off == inb.buf.len() {
				// Empty transition: reset, and free burst capacity down to the
				// steady bound (the Zig loop's posture, loop.zig) so one
				// slow-reader episode never pins its high-water bytes. Runs
				// only here — never on the reader's append path — so it adds
				// no hot-path contention.
				inb.buf.clear();
				inb.off = 0;
				if inb.buf.capacity() > NB_STEADY_BYTES {
					inb.buf.shrink_to(NB_STEADY_BYTES);
				}
			} else if inb.off >= inb.buf.len() - inb.off {
				// The consumed prefix has outgrown the pending bytes: compact
				// so `buf.len()` tracks the bounded pending count instead of
				// the total bytes ever buffered. Amortized O(1) per drained
				// byte, and the moved span is capped by the flow-control
				// bound.
				let off = inb.off;
				inb.buf.copy_within(off.., 0);
				let pending_len = inb.buf.len() - off;
				inb.buf.truncate(pending_len);
				inb.off = 0;
			}
			drop(inb);
			nb.read_room.notify_one();
			return n as isize;
		}
		if inb.eof {
			return 0;
		}
		if inb.err {
			return -1;
		}
		WOULD_BLOCK
	}));
	result.unwrap_or(-1)
}

/// Non-blocking write: copy the prefix that fits into the bounded outbound
/// buffer and wake the writer task. Returns the admitted byte count,
/// `PANCAKE_IROH_WOULD_BLOCK` (-2) when no outbound room remains, and -1 on
/// error. The connection must have been moved to the readiness surface with
/// `conn_set_nonblocking`. Borrows the handle.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_conn_try_write(conn: *mut PancakeIrohConn, buf: *const u8, len: usize) -> isize {
	let result = catch_unwind(AssertUnwindSafe(|| {
		let conn = unsafe { &*conn };
		let nb = match conn.nb.get() {
			Some(nb) => nb,
			None => return -1,
		};
		if len == 0 {
			return 0;
		}
		let src = unsafe { std::slice::from_raw_parts(buf, len) };
		let accepted = {
			let mut out = nb.outbound.lock().unwrap();
			enqueue_outbound(&mut out, src)
		};
		if accepted > 0 {
			nb.write_work.notify_one();
		}
		accepted
	}));
	result.unwrap_or(-1)
}
