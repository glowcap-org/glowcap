//! A session's one writer task. FLUSH and CLOSE actions wake it, and nothing
//! that reads waits on a write, so a partner slow to read cannot stop this side
//! reading. Passes are counted: a caller that must know its frames left waits
//! for the first pass that began after its request, which takes every frame
//! the core had queued by then.

use std::cell::Cell;
use std::rc::Rc;

use tokio::sync::Notify;

use crate::session_shared::SessionShared;
use crate::{Error, Result, sys};

#[derive(Clone, Copy, PartialEq, Eq)]
enum Phase {
	/// No FLUSH or CLOSE has started the task.
	Idle,
	Running,
	/// A CLOSE arrived: drain what the core queued before it, then close.
	Closing,
	Exited,
}

/// The writer state a `SessionShared` holds.
pub(crate) struct Outbound {
	phase: Cell<Phase>,
	// Holds a permit, so a request made before the writer parks is kept.
	wanted: Notify,
	// Signaled after every pass and when the writer exits.
	progress: Notify,
	started: Cell<u64>,
	finished: Cell<u64>,
}

impl Outbound {
	pub(crate) fn new() -> Self {
		Self {
			phase: Cell::new(Phase::Idle),
			wanted: Notify::new(),
			progress: Notify::new(),
			started: Cell::new(0),
			finished: Cell::new(0),
		}
	}
}

/// Wake the writer to drain the core's outbound frames, starting it on first
/// use. Returns before any byte is written, with the number of the pass that
/// takes every frame queued so far, for [`written`].
pub(crate) fn request_flush(shared: &Rc<SessionShared>) -> Result<u64> {
	let outbound = &shared.outbound;
	outbound.wanted.notify_one();
	let covering = outbound.started.get() + 1;
	if outbound.phase.get() == Phase::Idle {
		// Host-owned, because a CLOSE leaves the transport close to this task
		// and the Host's release must wait for it.
		let registration = shared.host.start_owned_task()?;
		let writer = Rc::clone(shared);
		let spawned = crate::host::try_spawn_local_handle(async move {
			let _registration = registration;
			write_loop(writer).await;
		});
		if spawned.is_none() {
			return Err(Error::with_detail(
				sys::ERR_INTERNAL,
				"outbound writing requires a running LocalSet".to_string(),
			));
		}
		outbound.phase.set(Phase::Running);
	}
	Ok(covering)
}

/// Wait until pass `covering` has finished. A writer that exited first closed
/// the transport, so frames it had not taken never leave.
pub(crate) async fn written(shared: &SessionShared, covering: u64) -> Result<()> {
	let outbound = &shared.outbound;
	loop {
		let progress = outbound.progress.notified();
		tokio::pin!(progress);
		progress.as_mut().enable();
		if outbound.finished.get() >= covering {
			return Ok(());
		}
		if outbound.phase.get() == Phase::Exited {
			return Err(Error::with_detail(
				sys::ERR_CLOSED,
				"the connection closed before its queued frames were written".to_string(),
			));
		}
		progress.await;
	}
}

/// Close the transport once the writer has drained every frame the core
/// queued ahead of this CLOSE, so a final abort or finish still reaches the
/// partner.
pub(crate) fn close_after_flush(shared: &Rc<SessionShared>) -> Result<()> {
	request_flush(shared)?;
	match shared.outbound.phase.get() {
		Phase::Running => shared.outbound.phase.set(Phase::Closing),
		Phase::Exited => shared.close_transport(),
		Phase::Idle | Phase::Closing => {}
	}
	Ok(())
}

/// Each wake drains everything queued, so FLUSH actions coalesce. Taken frames
/// lower the queue the core's backpressure measures, so a pass that wrote
/// schedules a drain for the work that pressure parked.
async fn write_loop(shared: Rc<SessionShared>) {
	let outbound = &shared.outbound;
	loop {
		let closed = shared.closed.notified();
		tokio::pin!(closed);
		closed.as_mut().enable();
		if shared.released.get() || shared.channel_retiring.get() {
			break;
		}
		tokio::select! {
			biased;
			() = outbound.wanted.notified() => {}
			() = closed => break,
		}
		// Read before the pass: a CLOSE that lands during it also leaves a
		// permit, so the next pass drains its frames and then closes.
		let closing = outbound.phase.get() == Phase::Closing;
		outbound.started.set(outbound.started.get() + 1);
		let drained = super::flush_outbound(&shared).await;
		outbound.finished.set(outbound.started.get());
		outbound.progress.notify_waiters();
		match drained {
			Err(error) => {
				shared.record_wire_failure(error);
				shared.close_transport();
				break;
			}
			Ok(_) if closing => {
				shared.close_transport();
				break;
			}
			Ok(true) => shared.host.schedule_kick_or_record(),
			Ok(false) => {}
		}
	}
	outbound.phase.set(Phase::Exited);
	outbound.progress.notify_waiters();
}
