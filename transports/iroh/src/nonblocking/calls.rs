//! The C-callable half of the non-blocking scale surface: the endpoint
//! readiness fd and drain, the try-accept, and the per-connection try-read and
//! try-write calls the completion loop drives over the state in the parent.
use super::*;

/// The OS readiness fd for this endpoint's scale surface: the read end of the
/// self-pipe the sidecar nudges whenever a connection (or the acceptor) becomes
/// ready. The completion loop registers this once and polls it. On wake it
/// calls `glowcap_iroh_sidecar_endpoint_drain_ready`, which clears the fd's
/// coalesced bytes before it drains records.
/// Returns -1 if the readiness channel could not be created. Borrows the handle.
/// The fd is owned by the endpoint and is valid until
/// `glowcap_iroh_sidecar_endpoint_free`.
///
/// # Safety
/// `ep` must be null or a live endpoint handle. Null is refused.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_iroh_sidecar_endpoint_readiness_fd(ep: *const GlowcapIrohEndpoint) -> i32 {
	if ep.is_null() {
		return -1;
	}
	let result = catch_unwind(AssertUnwindSafe(|| {
		// SAFETY: `ep` is non-null (checked above) and, per this function's `# Safety` contract, a live endpoint handle
		// from `glowcap_iroh_sidecar_endpoint_new` that the caller does not free during the call; the shared borrow
		// ends with this closure.
		let ep = unsafe { &*ep };
		match endpoint_readiness(ep) {
			Some(r) => r.reader.as_raw_fd(),
			None => -1,
		}
	}));
	result.unwrap_or(-1)
}

/// Drain pending readiness records into the caller's buffer. `out` points at
/// `out_cap` `GlowcapIrohReadyEvent` records. The call writes up to that many and
/// returns the count (>= 0), or -1 on error. No allocation per call. If more
/// records remain queued than fit, the endpoint re-nudges its readiness fd so the
/// loop wakes again to drain the rest. Borrows the handle.
///
/// # Safety
/// `ep` must be null or a live endpoint handle. When non-null, `out` must address
/// `out_cap` writable events. Invalid pointers or capacities are refused.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_iroh_sidecar_endpoint_drain_ready(
	ep: *const GlowcapIrohEndpoint,
	out: *mut GlowcapIrohReadyEvent,
	out_cap: usize,
) -> isize {
	if ep.is_null() {
		return -1;
	}
	if out.is_null() || out_cap == 0 {
		return 0;
	}
	if out_cap
		.checked_mul(std::mem::size_of::<GlowcapIrohReadyEvent>())
		.and_then(|bytes| isize::try_from(bytes).ok())
		.is_none()
	{
		return -1;
	}
	let result = catch_unwind(AssertUnwindSafe(|| {
		// SAFETY: `ep` is non-null (checked above) and, per this function's `# Safety` contract, a live endpoint handle
		// from `glowcap_iroh_sidecar_endpoint_new` that the caller does not free during the call; the shared borrow
		// ends with this closure.
		let ep = unsafe { &*ep };
		let r = match ep.readiness.get() {
			Some(r) => r,
			None => return 0,
		};
		// SAFETY: upheld by the caller after the pointer and capacity checks.
		let dest = unsafe { std::slice::from_raw_parts_mut(out, out_cap) };
		isize::try_from(r.drain(dest)).unwrap_or(-1)
	}));
	result.unwrap_or(-1)
}

/// Start the non-blocking acceptor for this endpoint: incoming connections are
/// pulled off the wire and surfaced through `endpoint_try_accept` instead of the
/// blocking `accept`. Idempotent. Returns 0 on success, -1 if the readiness
/// channel could not be created. Borrows the handle.
///
/// # Safety
/// `ep` must be null or a live endpoint handle. Null is refused.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_iroh_sidecar_endpoint_set_nonblocking_accept(ep: *mut GlowcapIrohEndpoint) -> i32 {
	if ep.is_null() {
		return -1;
	}
	let result = catch_unwind(AssertUnwindSafe(|| {
		// SAFETY: `ep` is non-null (checked above) and, per this function's `# Safety` contract, a live endpoint handle
		// from `glowcap_iroh_sidecar_endpoint_new` that the caller does not free during the call; the shared borrow
		// ends with this closure.
		let ep = unsafe { &*ep };
		if ep.accept.get().is_some() {
			return 0;
		}
		let readiness = match endpoint_readiness(ep) {
			Some(r) => r.clone(),
			None => return -1,
		};
		let acc = Arc::new(AcceptState {
			queue: Mutex::new(super::admission::Queue::new(readiness)),
		});
		if ep.accept.set(acc.clone()).is_err() {
			return 0; // raced with another caller; theirs won
		}
		ep.rt.spawn(nb_acceptor(ep.ep.clone(), ep.connect_timeout, acc));
		0
	}));
	result.unwrap_or(-1)
}

/// Start a fresh admission generation, or seal admission and drop the bounded
/// raw queue. Connections already claimed by the caller are unaffected.
///
/// # Safety
/// `ep` must be null or a live endpoint handle. Null is refused.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_iroh_sidecar_endpoint_admission(ep: *mut GlowcapIrohEndpoint, enabled: u8) -> i32 {
	if ep.is_null() {
		return -1;
	}
	catch_unwind(AssertUnwindSafe(|| {
		// SAFETY: `ep` is non-null (checked above) and, per this function's `# Safety` contract, a live endpoint handle
		// from `glowcap_iroh_sidecar_endpoint_new` that the caller does not free during the call; the shared borrow
		// ends with this closure.
		let ep = unsafe { &*ep };
		let Some(acc) = ep.accept.get() else {
			return -1;
		};
		// Detach under the admission lock; drop at most ACCEPT_QUEUE_BOUND raw
		// connections outside it, without minting handles or reader/writer tasks.
		let discarded = acc.queue.lock().unwrap().set_enabled(enabled != 0);
		drop(discarded);
		0
	}))
	.unwrap_or(-1)
}

/// Claim one connection the acceptor has pulled off the wire, or null when none
/// is waiting (the non-blocking counterpart of `accept`: null is `WOULD_BLOCK`,
/// not failure, the loop retries on the next `EV_ACCEPT`). The returned handle
/// is a fresh blocking connection. The loop calls `conn_set_nonblocking` on it
/// to bind it to the readiness surface. Returns an owned handle or null. The
/// endpoint must outlive the connection.
///
/// # Safety
/// `ep` must be null or a live endpoint handle. Null is refused.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_iroh_sidecar_endpoint_try_accept(
	ep: *mut GlowcapIrohEndpoint,
) -> *mut GlowcapIrohConn {
	if ep.is_null() {
		return std::ptr::null_mut();
	}
	let result = catch_unwind(AssertUnwindSafe(|| {
		// SAFETY: `ep` is non-null (checked above) and, per this function's `# Safety` contract, a live endpoint handle
		// from `glowcap_iroh_sidecar_endpoint_new` that the caller does not free during the call; the shared borrow
		// ends with this closure.
		let ep = unsafe { &*ep };
		let acc = ep.accept.get()?;
		let raw = acc.queue.lock().unwrap().pop()?;
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
///
/// # Safety
/// `ep` and `conn` must each be null or live handles. When both are live, `ep`
/// must have minted `conn`. Null pointers are refused.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_iroh_sidecar_conn_set_nonblocking(
	ep: *mut GlowcapIrohEndpoint,
	conn: *mut GlowcapIrohConn,
) -> i32 {
	if ep.is_null() || conn.is_null() {
		return -1;
	}
	let result = catch_unwind(AssertUnwindSafe(|| {
		// SAFETY: `ep` is non-null (checked above) and, per this function's `# Safety` contract, a live endpoint handle
		// from `glowcap_iroh_sidecar_endpoint_new` that the caller does not free during the call; the shared borrow
		// ends with this closure, and the spawned reader and writer tasks take the cloned `ep.ep` and moved streams,
		// not this reference.
		let ep = unsafe { &*ep };
		// SAFETY: `conn` is non-null (checked above) and, per this function's `# Safety` contract, a live connection
		// handle from `make_conn` minted by `ep` that the caller does not free during the call; the shared borrow ends
		// with this closure.
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
///
/// # Safety
/// `conn` must be null or a live connection handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_iroh_sidecar_conn_id(conn: *const GlowcapIrohConn) -> usize {
	let result = catch_unwind(AssertUnwindSafe(|| {
		if conn.is_null() {
			return 0;
		}
		// SAFETY: `conn` is non-null (checked above) and, per this function's `# Safety` contract, a live
		// connection handle from `make_conn`; this reads one `usize` field through a shared borrow.
		unsafe { (*conn).id }
	}));
	result.unwrap_or(0)
}

/// Non-blocking read: copy up to `len` buffered inbound bytes into `buf`. Returns
/// the byte count (> 0), 0 at clean end of stream, -1 on error, or
/// `GLOWCAP_IROH_WOULD_BLOCK` (-2) when no bytes are buffered yet. Draining the
/// buffer frees room for the reader task to resume. The connection must have been
/// moved to the readiness surface with `conn_set_nonblocking`. Borrows the handle.
///
/// # Safety
/// `conn` must be null or a live connection handle. For nonzero `len`, `buf` must
/// address `len` writable bytes. Null pointers are refused defensively.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_iroh_sidecar_conn_try_read(
	conn: *mut GlowcapIrohConn,
	buf: *mut u8,
	len: usize,
) -> isize {
	if conn.is_null() {
		return -1;
	}
	if len == 0 {
		return 0;
	}
	if buf.is_null() {
		return -1;
	}
	let result = catch_unwind(AssertUnwindSafe(|| {
		// SAFETY: `conn` is non-null (checked above) and, per this function's `# Safety` contract, a live connection
		// handle from `make_conn` that the caller does not free during the call; the shared borrow ends with this
		// closure.
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
				// SAFETY: `buf` is non-null (checked above) and the `# Safety` contract has the caller keep `len`
				// writable bytes at `buf`; `n` is at most `len`, and the slice is the only reference to those bytes
				// while it copies out of the inbound buffer.
				let dest = unsafe { std::slice::from_raw_parts_mut(buf, n) };
				dest.copy_from_slice(&inb.buf[inb.off..inb.off + n]);
				inb.off += n;
			}
			if inb.off == inb.buf.len() {
				// Empty transition: reset, and free burst capacity down to the
				// steady bound (the Zig loop's posture, loop.zig) so one
				// slow-reader episode never pins its high-water bytes. Runs
				// only here, never on the reader's append path, so it adds
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
			return isize::try_from(n).unwrap_or(-1);
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
/// `GLOWCAP_IROH_WOULD_BLOCK` (-2) when no outbound room remains, and -1 on
/// error. The connection must have been moved to the readiness surface with
/// `conn_set_nonblocking`. Borrows the handle.
///
/// # Safety
/// `conn` must be null or a live connection handle. For nonzero `len`, `buf` must
/// address `len` readable bytes. Null pointers and unrepresentable lengths are
/// refused defensively.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_iroh_sidecar_conn_try_write(
	conn: *mut GlowcapIrohConn,
	buf: *const u8,
	len: usize,
) -> isize {
	if conn.is_null() {
		return -1;
	}
	if len == 0 {
		return 0;
	}
	if buf.is_null() || isize::try_from(len).is_err() {
		return -1;
	}
	let result = catch_unwind(AssertUnwindSafe(|| {
		// SAFETY: `conn` is non-null (checked above) and, per this function's `# Safety` contract, a live connection
		// handle from `make_conn` that the caller does not free during the call; the shared borrow ends with this
		// closure.
		let conn = unsafe { &*conn };
		let nb = match conn.nb.get() {
			Some(nb) => nb,
			None => return -1,
		};
		// SAFETY: upheld by the caller after the pointer and length checks.
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
