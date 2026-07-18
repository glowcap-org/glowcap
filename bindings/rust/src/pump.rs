//! The byte-fed embedder pump choreography the [`Session`](crate::Session)
//! drives: read raw bytes off the transport, hand them to the core's stream
//! delimiter (`pancake_host_session_feed_bytes`, which owns framing), drain the
//! host's action queue, and write what `pancake_host_session_take_outbound`
//! drains. CapTP verbs, hosting, and vows stay on `Session`; this module owns
//! the conn byte path (handshake, serve loop, feed, flush, feed-refusal, EOF /
//! `pancake_host_session_break_far_vows`).

use std::rc::Rc;

use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::host::{check_host, drain_pending_releases, host_last_error};
use crate::session_shared::{io_err, SessionShared, READ_CHUNK};
use crate::sys::driver as ffi;
use crate::{sys, AbortDomain, AbortInfo, Error, Result};

/// Drive a freshly opened connection's keyed handshake to an open session.
/// The signed `op:start-session` was encoded by the open; its FLUSH is on the
/// action queue, so the drain puts it on the wire first. The core stops
/// consuming at the frame that opens the session, so a fast partner's
/// application frames coalesced behind start-session stay buffered until the
/// serve loop — otherwise a pipelined fetch would answer before the object it
/// names exists. Abandonment on failure stays on `Session::establish`.
pub(crate) async fn run_handshake(shared: &Rc<SessionShared>) -> Result<()> {
	shared.host.kick_actions().await;
	let Some(mut reader) = shared.reader.borrow_mut().take() else {
		return Err(Error::with_detail(
			sys::ERR_INTERNAL,
			"the connection's read half is already taken".to_string(),
		));
	};
	let result = async {
		let mut chunk = vec![0u8; READ_CHUNK];
		while !shared.session_open() {
			let n = reader.read(&mut chunk).await.map_err(io_err)?;
			if n == 0 {
				return Err(Error::with_detail(
					sys::ERR_CLOSED,
					"session closed during the OCapN handshake".to_string(),
				));
			}
			feed(shared, &chunk[..n]).await?;
		}
		Ok(())
	}
	.await;
	*shared.reader.borrow_mut() = Some(reader);
	result
}

/// Run the inbound loop: read raw bytes, hand them to the core's stream
/// delimiter (behaviors run and vow completions queue inside the feed), and
/// drain the action queue. Returns when the connection closes cleanly; a
/// transport or protocol error ends the loop and the teardown below breaks
/// the vows.
pub(crate) async fn serve_loop(shared: Rc<SessionShared>) {
	let Some(mut reader) = shared.reader.borrow_mut().take() else {
		return;
	};
	let mut chunk = vec![0u8; READ_CHUNK];
	let result: Result<()> = async {
		// Frames that arrived behind the handshake's tail are still
		// buffered; dispatch them before parking on the wire.
		if !shared.inbox.borrow().is_empty() {
			feed(&shared, &[]).await?;
		}
		loop {
			if shared.released.get() {
				return Ok(());
			}
			tokio::select! {
				biased;
				_ = shared.closed.notified() => return Ok(()),
				_ = shared.gc_wakeup.notified() => {
					// A finalizer parked tokens; release them on this, the
					// pumping task.
					shared.drain_gc();
					shared.host.kick_actions().await;
				}
				read = reader.read(&mut chunk) => {
					match read {
						Ok(0) => return Ok(()), // clean EOF
						Ok(n) => feed(&shared, &chunk[..n]).await?,
						// A read cancelled by our own close is a clean
						// shutdown; any other failure ends the loop and the
						// teardown below breaks the vows.
						Err(error) => {
							if shared.closing() {
								return Ok(());
							}
							return Err(io_err(error));
						}
					}
				}
			}
		}
	}
	.await;
	// A feed refusal already wrote the typed op:abort for the partner and
	// the teardown below carries the local consequence; the error itself
	// has no caller on a background task.
	let _ = result;
	// The wire is gone: pending far vows can never settle, so break them
	// and release the conn, freeing the fd. Idempotent with an application
	// `close()`.
	if !shared.closing() {
		shared.closing.set(true);
		let message = b"session closed";
		let _ = unsafe {
			ffi::pancake_host_session_break_far_vows(
				shared.ptr.get(),
				message.as_ptr(),
				message.len(),
			)
		};
		// Route the break's FAIL completions before the release retires the
		// connection.
		shared.host.kick_actions().await;
		shared.close_transport();
	}
}

fn feed_raw(shared: &SessionShared, bytes: &[u8]) -> (i32, usize) {
	let mut consumed: usize = 0;
	let rc = unsafe {
		ffi::pancake_host_session_feed_bytes(
			shared.ptr.get(),
			bytes.as_ptr(),
			bytes.len(),
			&mut consumed,
		)
	};
	(rc, consumed)
}

/// Append freshly read bytes onto the inbox and feed the core's stream
/// delimiter: the session's codec splits each complete frame off the front —
/// both codecs, both frame shapes, the frame cap enforced during the scan —
/// and dispatches it (behavior trampolines fire and completions queue
/// inside), then the actions the dispatch queued drain. Steady state (empty
/// inbox) borrows `chunk` for one synchronous feed — zero-copy; only when a
/// partial frame already straddles two reads is the burst coalesced into the
/// inbox Vec. Only the unconsumed tail stays in the inbox. The inbox is taken
/// out for the coalesce feed so no `RefCell` borrow is held across an FFI call
/// that can fire the trampoline.
pub(crate) async fn feed(shared: &Rc<SessionShared>, chunk: &[u8]) -> Result<()> {
	let mut refusal: Option<i32> = None;
	if shared.inbox.borrow().is_empty() {
		if chunk.is_empty() {
			return Ok(());
		}
		if !shared.released.get() {
			let (rc, consumed) = feed_raw(shared, chunk);
			if rc != sys::OK {
				refusal = Some(rc);
			} else if consumed < chunk.len() {
				shared
					.inbox
					.borrow_mut()
					.extend_from_slice(&chunk[consumed..]);
			}
		}
	} else {
		{
			let mut inbox = shared.inbox.borrow_mut();
			inbox.extend_from_slice(chunk);
		}
		// One call: the core delimits and dispatches every complete frame in
		// the buffer itself, stops at a partial tail, and during the
		// handshake stops at the frame that opens the session.
		let mut buf = std::mem::take(&mut *shared.inbox.borrow_mut());
		if !shared.released.get() {
			let (rc, consumed) = feed_raw(shared, &buf);
			if rc != sys::OK {
				refusal = Some(rc);
			} else {
				buf.drain(..consumed);
			}
		}
		let mut inbox = shared.inbox.borrow_mut();
		buf.extend_from_slice(&inbox);
		*inbox = buf;
	}
	drain_pending_releases();
	if let Some(rc) = refusal {
		return Err(feed_refusal(shared, rc).await);
	}
	shared.host.kick_actions().await;
	Ok(())
}

/// The feed refusal choreography: capture last_error / last_abort before
/// another verb can clobber them, then run the shared action drain so the
/// projected op:abort (and any CLOSE/FAIL queued with it) leave through the
/// same spine as a steady FLUSH — not a private `take_outbound` path.
async fn feed_refusal(shared: &Rc<SessionShared>, rc: i32) -> Error {
	let message = host_last_error();
	let abort = last_abort(shared);
	// The transport may already be gone; the local typed error stands.
	shared.host.kick_actions().await;
	Error::with_transport_detail(rc, message).with_abort(abort)
}

/// The typed cause of this CapTP session's most recent local dispatch failure,
/// or `None` when none has been recorded. The flat per-feed error code
/// names the failure family; this names the member.
fn last_abort(shared: &SessionShared) -> Option<AbortInfo> {
	if shared.released.get() {
		return None;
	}
	let mut raw: sys::PancakeLastAbort = unsafe { core::mem::zeroed() };
	let rc = unsafe { ffi::pancake_host_session_last_abort(shared.ptr.get(), &mut raw) };
	if rc == sys::WOULD_BLOCK {
		return None; // no abort recorded
	}
	if rc != sys::OK {
		// Best-effort diagnostic on an already-refused feed: the primary
		// refusal error stands, and a failed read only loses the detail.
		return None;
	}
	// The C views are process-static; copy them into owned strings so the
	// info outlives any later host call.
	let text = |ptr: *const u8, len: usize| -> String {
		if ptr.is_null() || len == 0 {
			String::new()
		} else {
			String::from_utf8_lossy(unsafe { core::slice::from_raw_parts(ptr, len) }).into_owned()
		}
	};
	Some(AbortInfo {
		domain: AbortDomain::from_abi(raw.domain),
		kind: (raw.has_kind != 0).then(|| text(raw.kind_name, raw.kind_name_len)),
		message: text(raw.message, raw.message_len),
		error_name: text(raw.error_name, raw.error_name_len),
	})
}

/// Drain every encoded outbound frame on this CapTP session and write it to
/// the transport — how a FLUSH action lands. Writes serialize on the write
/// half's lock, so frames stay whole and in submission order. The managed
/// frame is held across the awaited write and released after it — zero
/// frame copy.
pub(crate) async fn flush_outbound(shared: &Rc<SessionShared>) -> Result<()> {
	let writer = Rc::clone(&shared.writer);
	let mut guard = writer.lock().await;
	loop {
		if shared.released.get() {
			return Ok(());
		}
		let mut raw: sys::PancakeManagedFrame = unsafe { core::mem::zeroed() };
		let rc = unsafe { ffi::pancake_host_session_take_outbound(shared.ptr.get(), &mut raw) };
		if rc == sys::WOULD_BLOCK {
			break;
		}
		check_host(rc)?;
		let frame = FrameGuard(raw);
		let Some(sink) = guard.as_mut() else {
			return Ok(()); // the transport is gone; the frame is released
		};
		sink.write_all(frame.bytes()).await.map_err(io_err)?;
	}
	if let Some(sink) = guard.as_mut() {
		sink.flush().await.map_err(io_err)?;
	}
	Ok(())
}

// Holds one drained managed frame across the awaited transport write and
// releases it after — the zero-copy outbound path.
struct FrameGuard(sys::PancakeManagedFrame);

impl FrameGuard {
	fn bytes(&self) -> &[u8] {
		if self.0.bytes.is_null() || self.0.len == 0 {
			&[]
		} else {
			unsafe { core::slice::from_raw_parts(self.0.bytes, self.0.len) }
		}
	}
}

impl Drop for FrameGuard {
	fn drop(&mut self) {
		unsafe { sys::pancake_managed_frame_release(&mut self.0) };
	}
}
