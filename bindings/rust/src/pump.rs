//! The byte-fed embedder pump choreography the [`Session`](crate::Session)
//! drives: read raw bytes off the transport, hand them to the core's stream
//! delimiter (`glowcap_host_session_feed_bytes`, which owns framing), drain the
//! host's action queue, and write what `glowcap_host_session_take_outbound`
//! drains. CapTP verbs, hosting, and vows stay on `Session`; this module owns
//! the conn byte path (handshake, serve loop, feed, flush, feed-refusal, EOF /
//! `glowcap_host_session_transport_closed`).

use std::rc::Rc;

use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::host::{check_host, host_last_error};
use crate::session_shared::{io_err, SessionShared, READ_CHUNK};
use crate::sys::host as ffi;
use crate::trampoline::DeliverGuard;
use crate::{sys, AbortDomain, AbortInfo, Error, Result};

/// Drive a freshly opened connection's keyed handshake to an open session.
/// The signed `op:start-session` was encoded by the open; its FLUSH is on the
/// action queue, so the drain puts it on the wire first. The core stops
/// consuming at the frame that opens the session, so a fast partner's
/// application frames coalesced behind start-session stay buffered until the
/// Host-owned resume step — otherwise a pipelined fetch would answer before
/// the object it names exists. Abandonment on failure stays on
/// `Session::establish`.
#[cfg(any(test, feature = "iroh"))]
pub(crate) async fn run_handshake(shared: &Rc<SessionShared>) -> Result<()> {
	shared.host.kick_actions().await?;
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
					"connection closed during the OCapN handshake".to_string(),
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
pub(crate) async fn serve_loop(shared: Rc<SessionShared>) -> Result<()> {
	let Some(mut reader) = shared.reader.borrow_mut().take() else {
		return Err(Error::with_detail(
			sys::ERR_INTERNAL,
			"the connection's read half is already taken".to_string(),
		));
	};
	let mut chunk = vec![0u8; READ_CHUNK];
	let mut outcome: Result<()> = async {
		resume_feed(&shared).await?;
		loop {
			if shared.released.get() {
				return Ok(());
			}
			tokio::select! {
				biased;
				_ = shared.closed.notified() => return Ok(()),
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
	// A feed refusal already wrote the typed op:abort for the partner. Preserve
	// that primary error while teardown carries the local consequence.
	// The wire is gone: report the physical fact so the core retires the
	// session and settles pending work, then release the connection.
	// Idempotent with an application `close()`.
	if !shared.released.get() {
		shared.closing.set(true);
		let message = b"connection closed";
		let reported = check_host(unsafe {
			ffi::glowcap_host_session_transport_closed(shared.ptr.get(), message.as_ptr(), message.len())
		});
		if outcome.is_ok() {
			outcome = reported;
		}
		// Route the break's FAIL completions before the release retires the
		// connection.
		if let Err(error) = shared.host.kick_actions().await {
			if outcome.is_ok() {
				outcome = Err(error);
			}
		}
		shared.close_transport();
	}
	outcome
}

/// Feed freshly read bytes to the core's stream delimiter: the session's
/// codec splits each complete frame off the front — both codecs, both frame
/// shapes, the frame cap enforced during the scan — and dispatches it
/// (behavior trampolines fire and completions queue inside), then the
/// actions the dispatch queued drain. The library owns the unconsumed tail —
/// a partial frame straddling two reads stays buffered in the session — so
/// one borrowed call moves the whole chunk. The serve loop resumes any
/// handshake-held tail through `resume_feed`.
pub(crate) async fn feed(shared: &Rc<SessionShared>, chunk: &[u8]) -> Result<()> {
	loop {
		if shared.released.get() {
			return Ok(());
		}
		let _deliver = DeliverGuard::enter(shared);
		let rc = unsafe {
			ffi::glowcap_host_session_feed_bytes(
				shared.ptr.get(),
				if chunk.is_empty() {
					std::ptr::null()
				} else {
					chunk.as_ptr()
				},
				chunk.len(),
			)
		};
		drop(_deliver);
		crate::finalizer::drain();
		// Fed bytes can advance close-relevant state (a partner's finish
		// acknowledgment, a settle) even when the drain below finds nothing
		// queued, so every feed wakes the parked close drivers itself.
		shared.host.note_close_activity();
		if rc == sys::OK {
			break;
		}
		if rc == sys::WOULD_BLOCK {
			shared.host.kick_actions().await?;
			continue;
		}
		return Err(feed_refusal(shared, rc).await);
	}
	shared.host.kick_actions().await?;
	Ok(())
}

async fn resume_feed(shared: &Rc<SessionShared>) -> Result<()> {
	loop {
		if shared.released.get() {
			return Ok(());
		}
		let _deliver = DeliverGuard::enter(shared);
		let rc = unsafe { ffi::glowcap_host_session_resume_feed(shared.ptr.get()) };
		drop(_deliver);
		crate::finalizer::drain();
		shared.host.note_close_activity();
		if rc == sys::OK {
			break;
		}
		if rc == sys::WOULD_BLOCK {
			shared.host.kick_actions().await?;
			continue;
		}
		return Err(feed_refusal(shared, rc).await);
	}
	shared.host.kick_actions().await?;
	Ok(())
}

/// The feed refusal choreography: capture last_error / last_abort before
/// another verb can clobber them, then run the shared action drain so the
/// projected op:abort (and any CLOSE/FAIL queued with it) leave through the
/// same spine as a steady FLUSH — not a private `take_outbound` path.
async fn feed_refusal(shared: &Rc<SessionShared>, rc: i32) -> Error {
	let message = host_last_error();
	let (abort, abort_failure) = match last_abort(shared) {
		Ok(abort) => (abort, None),
		Err(error) => (None, Some(error)),
	};
	// The local typed refusal remains primary; retain every diagnostic failure
	// that happened while projecting it instead of silently dropping context.
	let drain_failure = shared.host.kick_actions().await.err();
	let mut details = Vec::new();
	if let Some(primary) = message {
		details.push(primary);
	}
	if let Some(error) = abort_failure {
		details.push(format!("last-abort diagnostic also failed: {error}"));
	}
	if let Some(error) = drain_failure {
		details.push(format!("action drain also failed: {error}"));
	}
	let detail = (!details.is_empty()).then(|| details.join("; "));
	Error::with_transport_detail(rc, detail).with_abort(abort)
}

/// The typed cause of this CapTP session's most recent local dispatch failure,
/// or `None` when none has been recorded. The flat per-feed error code
/// names the failure family; this names the member.
fn last_abort(shared: &SessionShared) -> Result<Option<AbortInfo>> {
	if shared.released.get() {
		return Ok(None);
	}
	let mut raw: sys::GlowcapLastAbort = unsafe { core::mem::zeroed() };
	let rc = unsafe { ffi::glowcap_host_session_last_abort(shared.ptr.get(), &mut raw) };
	if rc == sys::WOULD_BLOCK {
		return Ok(None); // no abort recorded
	}
	crate::host::check_host(rc)?;
	// The C views are process-static; copy them into owned strings so the
	// info outlives any later host call.
	let text = |ptr: *const u8, len: usize| -> String {
		if ptr.is_null() || len == 0 {
			String::new()
		} else {
			String::from_utf8_lossy(unsafe { core::slice::from_raw_parts(ptr, len) }).into_owned()
		}
	};
	Ok(Some(AbortInfo {
		domain: AbortDomain::from_abi(raw.domain)?,
		kind: (raw.has_kind != 0).then(|| text(raw.kind_name, raw.kind_name_len)),
		message: text(raw.message, raw.message_len),
		error_name: text(raw.error_name, raw.error_name_len),
		abort_delivery_error_name: (!raw.abort_delivery_error_name.is_null() && raw.abort_delivery_error_name_len != 0)
			.then(|| text(raw.abort_delivery_error_name, raw.abort_delivery_error_name_len)),
		secondary_error_name: (!raw.secondary_error_name.is_null() && raw.secondary_error_name_len != 0)
			.then(|| text(raw.secondary_error_name, raw.secondary_error_name_len)),
		secondary_error_count: raw.secondary_error_count,
	}))
}

/// Drain every encoded outbound frame on this CapTP session and write it to
/// the byte-stream transport, which is how a FLUSH action lands. The managed
/// frame is held across both writes and released after them, so the canonical
/// Syrup byte-string prefix uses stack storage and the frame is not copied.
///
/// Writes serialize on the write half's lock, which keeps them in submission
/// order. It does not make one write atomic: `write_all` is not
/// cancellation-safe, so a caller who drops this future part-way through a
/// frame, which `tokio::time::timeout` around a send does, leaves a partial
/// frame on the wire. The partner's framing cannot recover from that, so the
/// session is marked torn and refuses to write again rather than appending to
/// a stream nobody can parse.
pub(crate) async fn flush_outbound(shared: &Rc<SessionShared>) -> Result<()> {
	if shared.torn.get() {
		return Err(Error::from_code(sys::ERR_CLOSED));
	}
	let writer = Rc::clone(&shared.writer);
	let guard = writer.lock().await;
	let mut guard = WriterLease { inner: guard, shared };
	let mut in_flight = None;
	loop {
		if shared.released.get() {
			return Ok(());
		}
		let mut raw: sys::GlowcapManagedFrame = unsafe { core::mem::zeroed() };
		let mut prefix = [0u8; sys::HOST_OUTBOUND_PREFIX_CAP];
		let mut prefix_len = 0usize;
		let rc = unsafe {
			ffi::glowcap_host_session_take_outbound(
				shared.ptr.get(),
				&mut raw,
				prefix.as_mut_ptr(),
				prefix.len(),
				&mut prefix_len,
			)
		};
		if rc == sys::WOULD_BLOCK {
			break;
		}
		check_host(rc)?;
		let frame = FrameGuard(raw);
		let Some(sink) = guard.inner.as_mut() else {
			return Ok(()); // the transport is gone; the frame is released
		};
		// Once a frame leaves the core, cancellation is terminal until the
		// transport flush confirms every buffered byte was handed onward.
		if in_flight.is_none() {
			in_flight = Some(TornOnDrop { shared });
		}
		write_all_or_closed(shared, sink, &prefix[..prefix_len]).await?;
		write_all_or_closed(shared, sink, frame.bytes()).await?;
	}
	if let Some(sink) = guard.inner.as_mut() {
		flush_or_closed(shared, sink).await?;
	}
	if let Some(in_flight) = in_flight {
		in_flight.finished();
	}
	Ok(())
}

async fn write_all_or_closed(
	shared: &SessionShared,
	sink: &mut Box<dyn tokio::io::AsyncWrite + Unpin>,
	bytes: &[u8],
) -> Result<()> {
	tokio::select! {
		biased;
		_ = shared.closed.notified() => Err(Error::from_code(sys::ERR_CLOSED)),
		result = sink.write_all(bytes) => result.map_err(io_err),
	}
}

async fn flush_or_closed(shared: &SessionShared, sink: &mut Box<dyn tokio::io::AsyncWrite + Unpin>) -> Result<()> {
	tokio::select! {
		biased;
		_ = shared.closed.notified() => Err(Error::from_code(sys::ERR_CLOSED)),
		result = sink.flush() => result.map_err(io_err),
	}
}

// Own the async writer lock for one drain. Session close cannot synchronously
// take that lock while a write awaits, so the lease itself retires the sink
// when close raced it or cancellation marked the stream torn.
struct WriterLease<'a> {
	inner: tokio::sync::MutexGuard<'a, Option<Box<dyn tokio::io::AsyncWrite + Unpin>>>,
	shared: &'a SessionShared,
}

impl Drop for WriterLease<'_> {
	fn drop(&mut self) {
		if self.shared.released.get() || self.shared.torn.get() {
			*self.inner = None;
		}
	}
}

// Marks the session torn unless every transferred frame reaches a successful
// transport flush. A dropped write future is indistinguishable from a partial
// frame or a frame stranded in a buffered sink.
struct TornOnDrop<'a> {
	shared: &'a Rc<SessionShared>,
}

impl TornOnDrop<'_> {
	fn finished(self) {
		core::mem::forget(self);
	}
}

impl Drop for TornOnDrop<'_> {
	fn drop(&mut self) {
		self.shared.torn.set(true);
	}
}

// Holds one drained managed frame across the awaited transport write and
// releases it after — the zero-copy outbound path.
struct FrameGuard(sys::GlowcapManagedFrame);

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
		unsafe { sys::glowcap_managed_frame_release(&mut self.0) };
	}
}
