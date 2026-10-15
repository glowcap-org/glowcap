use super::*;

// One iroh connection pointer, released exactly once: when the owning
// `Stream` drops. No sidecar call ever parks on the connection (the loop's
// only blocking call touches the endpoint), so releasing it never races a parked
// read: the teardown hazard the thread-per-connection path had.
pub(super) struct ConnPtr(pub(super) *mut GlowcapIrohConn);

// SAFETY: `Send` is required: an `Stream` moves between threads (the relay
// pumps one inside `tokio::spawn` tasks on a multithreaded runtime), so
// `glowcap_iroh_conn_try_read`/`try_write` run on whichever thread polls it and
// `Drop`'s `glowcap_iroh_conn_release` on whichever thread drops it, not the
// thread that dialed. That FFI use is defined because the sidecar connection is
// internally synchronized (mutex-guarded stream state over iroh's `Send + Sync`
// connection), and the pointer is single-owner (one `Stream` field), so the
// release runs exactly once. Not `Sync`: no `&ConnPtr` is ever shared across
// threads: the loop addresses the connection by its `key: usize`, never
// through this pointer.
unsafe impl Send for ConnPtr {}

impl Drop for ConnPtr {
	fn drop(&mut self) {
		// SAFETY: `self.0` is the connection pointer from `glowcap_iroh_netlayer_finish_connect` or `try_accept`, owned
		// by exactly one `ConnPtr` (one `Stream` field), so this `Drop` is its one release; the header says no call
		// parks on the connection.
		unsafe { ffi::glowcap_iroh_conn_release(self.0) };
	}
}

// Per-connection readiness state. A loop connection is single-owner (one task
// drives it), so at most one task waits to read and one to write; a `*_ready`
// flag holds an edge that arrived before its waiter so no wakeup is lost.
#[derive(Default)]
pub(super) struct ConnSlot {
	pub(super) read_waker: Option<Waker>,
	pub(super) write_waker: Option<Waker>,
	pub(super) readable: bool,
	pub(super) writable: bool,
	pub(super) closed: bool,
}

#[derive(Default)]
pub(super) struct LoopState {
	pub(super) conns: HashMap<usize, ConnSlot>,
	dials: HashMap<usize, oneshot::Sender<Result<usize>>>,
	accept_waker: Option<Waker>,
	accept_pending: usize,
	closed: bool,
}

/// The per-netlayer readiness dispatcher for the iroh loop surface (ADR-0057).
///
/// It registers the netlayer's single readiness fd with tokio's reactor (an
/// [`AsyncFd`] over a dup of the fd) and, when the fd signals, drains the pending
/// readiness records and wakes the task (a `poll_read`/`poll_write`, or an
/// accept) waiting on each. Everything runs on one reactor task, no thread per
/// connection, and because the drain touches only the endpoint, never a
/// per-connection buffer, a connection can be released at any time without racing
/// a read. A requested shutdown wakes every waiter. Explicit owners join the
/// task before releasing the endpoint, so the drain can never touch a freed
/// endpoint. This is the Rust
/// sibling of the Deno binding's `IrohLoop` and Zig's
/// `driver.HostRuntime` over `iroh.MultiplexedAdapter`: one reactor
/// multiplexes many connections.
pub(crate) struct IrohLoop {
	netlayer: Arc<NetlayerRaw>,
	pub(super) state: Mutex<LoopState>,
	task: Mutex<Option<tokio::task::JoinHandle<()>>>,
	stop: AtomicBool,
	next_request: AtomicUsize,
	notify: Notify,
}

impl IrohLoop {
	/// Register the netlayer's readiness fd with the reactor and spawn the single
	/// dispatcher task. The loop is already armed (the netlayer arms it at
	/// construction), so this only stands up the reactor side.
	pub(super) fn start(netlayer: Arc<NetlayerRaw>) -> Result<Arc<IrohLoop>> {
		// SAFETY: `netlayer.raw` is the `GlowcapIrohNetlayer` handle that the `Arc<NetlayerRaw>` argument keeps alive;
		// the callee returns the fd by value.
		let raw_fd: RawFd = unsafe { ffi::glowcap_iroh_netlayer_readiness_fd(netlayer.raw) };
		if raw_fd < 0 {
			return Err(Error::with_transport_detail(sys::ERR_IO, iroh_last_error()));
		}
		// Dup the borrowed fd so the `AsyncFd` owns and closes its own copy on
		// drop, never the netlayer's fd. The dup shares the same socket, so its
		// readiness tracks the original and `drain_ready` (which reads the
		// original) clears both.
		// SAFETY: `raw_fd` is the netlayer's readiness fd, non-negative (checked above), owned by the netlayer and
		// valid until its release, which cannot run while `netlayer` is held here; the borrow lasts only for this
		// `try_clone_to_owned` dup.
		let owned: OwnedFd = unsafe { BorrowedFd::borrow_raw(raw_fd) }
			.try_clone_to_owned()
			.map_err(|_| Error::from_code(sys::ERR_IO))?;
		let iloop = Arc::new(IrohLoop {
			netlayer,
			state: Mutex::new(LoopState::default()),
			task: Mutex::new(None),
			stop: AtomicBool::new(false),
			next_request: AtomicUsize::new(1),
			notify: Notify::new(),
		});
		let runner = Arc::clone(&iloop);
		let handle = tokio::spawn(async move {
			match AsyncFd::new(owned) {
				Ok(afd) => runner.run(afd).await,
				Err(_) => runner.wake_all_closed(),
			}
		});
		*lock_iroh(&iloop.task, "iroh-loop-task-lock-poison") = Some(handle);
		Ok(iloop)
	}

	pub(super) fn register(&self, conn: usize) {
		// SAFETY: `conn` is the `usize` form of a `*mut GlowcapIrohConn` its `Stream` still owns through `ConnPtr`, so
		// it is live for the call; the callee returns the identity by value.
		let key = unsafe { ffi::glowcap_iroh_conn_id(conn as *mut GlowcapIrohConn) };
		lock_iroh(&self.state, "iroh-loop-state-lock-poison")
			.conns
			.insert(key, ConnSlot::default());
	}

	pub(super) fn unregister(&self, key: usize) {
		let wakers = {
			let mut st = lock_iroh(&self.state, "iroh-loop-state-lock-poison");
			remove_conn_wakers(&mut st, key)
		};
		wakers.wake_all();
	}

	pub(super) async fn dial(&self, node_id: &str, hints: &str) -> Result<usize> {
		let request_id = self
			.next_request
			.try_update(Ordering::Relaxed, Ordering::Relaxed, |next| next.checked_add(1))
			.map_err(|_| Error::from_code(sys::ERR_INTERNAL))?;
		let (sender, receiver) = oneshot::channel();
		lock_iroh(&self.state, "iroh-loop-state-lock-poison")
			.dials
			.insert(request_id, sender);
		// SAFETY: `self.netlayer.raw` is the `GlowcapIrohNetlayer` handle the `Arc<NetlayerRaw>` keeps alive; explicit
		// owners join the dispatcher task before releasing it; `node_id` and `hints` are borrowed `str`s whose pointers
		// and lengths stay live for the call, and the callee parses them before returning.
		let rc = unsafe {
			ffi::glowcap_iroh_netlayer_start_connect(
				self.netlayer.raw,
				request_id,
				node_id.as_ptr(),
				node_id.len(),
				hints.as_ptr(),
				hints.len(),
			)
		};
		if rc != sys::OK {
			lock_iroh(&self.state, "iroh-loop-state-lock-poison")
				.dials
				.remove(&request_id);
			return Err(Error::with_transport_detail(rc, iroh_last_error()));
		}
		let mut guard = DialGuard {
			netlayer: Arc::clone(&self.netlayer),
			request_id,
			armed: true,
		};
		let result = receiver
			.await
			.unwrap_or_else(|_| Err(Error::from_code(sys::ERR_CLOSED)));
		guard.armed = false;
		result
	}

	// The dispatcher task: park on the readiness fd, and on each wake drain the
	// queue and route records to their waiters. The drain touches the netlayer
	// (`Arc`-kept-alive), never a per-connection buffer.
	async fn run(self: Arc<Self>, afd: AsyncFd<OwnedFd>) {
		loop {
			if self.stop.load(Ordering::Acquire) {
				break;
			}
			tokio::select! {
				biased;
				_ = self.notify.notified() => continue, // shutdown asked; re-check stop
				guard = afd.readable() => match guard {
					Ok(mut g) => {
						// Clear the reactor's readiness BEFORE draining. The other
						// order loses an edge: a record and its fd wakeup landing
						// between the drain and the clear are cleared away, and,
						// edge-triggered, with no successor record coming, the
						// final SETTLE strands. Cleared first, a record landing
						// mid-drain re-arms the fd, and the worst case is one
						// spurious wake whose drain reads short. Then drain until
						// a short count.
						g.clear_ready();
						self.drain();
					}
					Err(_) => break,
				},
			}
		}
		self.wake_all_closed();
	}

	// Drain the ready-queue in batches until a short count, routing each record
	// to its waiter (collected, woken after the lock is released).
	fn drain(&self) {
		let nl = self.netlayer.raw;
		let mut buf = [GlowcapIrohReadyEvent { subject: 0, events: 0 }; DRAIN_READY_CAP];
		loop {
			let mut count: usize = 0;
			let rc =
				// SAFETY: `self.netlayer.raw` is the `GlowcapIrohNetlayer` handle the `Arc<NetlayerRaw>` keeps alive;
				// explicit owners join the dispatcher task before releasing it; `buf` is a local array of
				// `DRAIN_READY_CAP` events, which is the capacity passed, and `count` is a local out-parameter; only
				// the single dispatcher task drains, as the header requires.
				unsafe { ffi::glowcap_iroh_netlayer_drain_ready(nl, buf.as_mut_ptr(), DRAIN_READY_CAP, &mut count) };
			if rc != sys::OK || count == 0 {
				break;
			}
			for ev in buf.iter().take(count) {
				if ev.events & GLOWCAP_IROH_EV_CONNECT != 0 {
					let mut conn: *mut GlowcapIrohConn = core::ptr::null_mut();
					// SAFETY: as `drain_ready` above for the netlayer handle `nl`; `ev.subject` is the request id of a
					// dial recorded in `dials`, and `conn` is a local out-parameter the callee fills on success.
					let rc = unsafe { ffi::glowcap_iroh_netlayer_finish_connect(nl, ev.subject, &mut conn) };
					let result = if rc == sys::OK {
						Ok(conn as usize)
					} else {
						Err(Error::with_transport_detail(rc, iroh_last_error()))
					};
					if let Some(sender) = lock_iroh(&self.state, "iroh-loop-state-lock-poison")
						.dials
						.remove(&ev.subject)
					{
						// A dropped dial future leaves the sender in the map until
						// this sole terminal event retires it. If delivery finds
						// the receiver gone, reclaim a successful connection here.
						if let Err(Ok(abandoned_conn)) = sender.send(result) {
							// SAFETY: `abandoned_conn` is the pointer `glowcap_iroh_netlayer_finish_connect` just
							// filled, returned inside the failed `send`, so no receiver or `ConnPtr` owns it and this
							// is its one release.
							unsafe { ffi::glowcap_iroh_conn_release(abandoned_conn as *mut GlowcapIrohConn) };
						}
					} else if rc == sys::OK {
						// SAFETY: `conn` was filled by the successful `glowcap_iroh_netlayer_finish_connect` above and
						// no dial waiter exists for it, so nothing else owns it and this is its one release.
						unsafe { ffi::glowcap_iroh_conn_release(conn) };
					}
					continue;
				}
				let mut wakers = ReadyWakers::default();
				{
					let mut st = lock_iroh(&self.state, "iroh-loop-state-lock-poison");
					dispatch(&mut st, ev.subject, ev.events, &mut wakers);
				}
				wakers.wake_all();
			}
			if count < DRAIN_READY_CAP {
				break;
			}
		}
	}

	fn wake_all_closed(&self) {
		let mut wakers: Vec<Waker> = Vec::new();
		let mut dials = Vec::new();
		{
			let mut st = lock_iroh(&self.state, "iroh-loop-state-lock-poison");
			st.closed = true;
			if let Some(w) = st.accept_waker.take() {
				wakers.push(w);
			}
			for slot in st.conns.values_mut() {
				slot.closed = true;
				wakers.extend(slot.read_waker.take());
				wakers.extend(slot.write_waker.take());
			}
			dials.extend(st.dials.drain().map(|(_, sender)| sender));
		}
		for sender in dials {
			// A failed send means the dial future was cancelled. Its FFI
			// request was cancelled above or reached its sole terminal event, and
			// this map no longer owns a connection handle.
			drop(sender.send(Err(Error::from_code(sys::ERR_CLOSED))));
		}
		for w in wakers {
			w.wake();
		}
	}

	/// Request loop shutdown and wake every waiter so parked pumps unwind.
	/// Explicit owners subsequently join the dispatcher. Destructor paths use
	/// `shutdown` to abort it as a backstop. Aborting only takes effect at an
	/// await point, never mid-`drain`, and the netlayer's `Arc` outlives the task,
	/// so a freed endpoint is never drained.
	fn request_shutdown(&self) {
		self.stop.store(true, Ordering::Release);
		let requests: Vec<usize> = lock_iroh(&self.state, "iroh-loop-state-lock-poison")
			.dials
			.keys()
			.copied()
			.collect();
		for request_id in requests {
			// SAFETY: `self.netlayer.raw` is the `GlowcapIrohNetlayer` handle the `Arc<NetlayerRaw>` keeps alive;
			// explicit owners join the dispatcher task before releasing it; `request_id` is a plain integer naming a
			// dial this loop still tracks.
			unsafe {
				ffi::glowcap_iroh_netlayer_cancel_connect(self.netlayer.raw, request_id);
			}
		}
		self.wake_all_closed();
		self.notify.notify_waiters();
	}

	/// Request shutdown and join the dispatcher. Explicit owners use this
	/// barrier before releasing the endpoint. Drop uses `shutdown` below as a
	/// last resort because it cannot await.
	pub(super) async fn shutdown_and_join(&self) -> Result<()> {
		self.request_shutdown();
		// Take the handle in its own statement so the mutex guard drops
		// before the await: a guard held across it makes the future !Send,
		// and the close registration runs this on a multi-thread runtime.
		let handle = lock_iroh(&self.task, "iroh-loop-task-lock-poison").take();
		if let Some(h) = handle {
			h.await.map_err(|_| Error::from_code(sys::ERR_INTERNAL))?;
		}
		Ok(())
	}

	/// Request shutdown and abort the dispatcher when no async barrier is
	/// available. This is only for cancellation/destructor paths.
	pub(super) fn shutdown(&self) {
		self.request_shutdown();
		if let Some(h) = lock_iroh(&self.task, "iroh-loop-task-lock-poison").take() {
			h.abort();
		}
	}
}

fn remove_conn_wakers(st: &mut LoopState, key: usize) -> ReadyWakers {
	let mut wakers = ReadyWakers::default();
	if let Some(mut slot) = st.conns.remove(&key) {
		wakers.push(slot.read_waker.take());
		wakers.push(slot.write_waker.take());
	}
	wakers
}

// One drained record is coalesced by subject before Rust sees it, so it can
// wake one accept waiter or one connection's read/write pair.
#[derive(Default)]
struct ReadyWakers([Option<Waker>; 2]);

impl ReadyWakers {
	fn push(&mut self, waker: Option<Waker>) {
		if let Some(waker) = waker {
			if self.0[0].is_none() {
				self.0[0] = Some(waker);
			} else {
				assert!(
					self.0[1].is_none(),
					"one iroh readiness record can wake at most two tasks"
				);
				self.0[1] = Some(waker);
			}
		}
	}

	fn wake_all(self) {
		for waker in self.0.into_iter().flatten() {
			waker.wake();
		}
	}
}

// Route one readiness record to its waiter (collected, woken after the lock is
// released). An accept record carries a null connection.
fn dispatch(st: &mut LoopState, conn_key: usize, events: u32, wakers: &mut ReadyWakers) {
	if events & GLOWCAP_IROH_EV_ACCEPT != 0 {
		// Record the pending accept first, then wake the byte-fed channel waiter;
		// the count survives a wake that races waiter registration.
		st.accept_pending += 1;
		wakers.push(st.accept_waker.take());
		return;
	}
	if let Some(slot) = st.conns.get_mut(&conn_key) {
		if events & GLOWCAP_IROH_EV_CLOSED != 0 {
			slot.closed = true;
		}
		if events & (GLOWCAP_IROH_EV_READABLE | GLOWCAP_IROH_EV_CLOSED) != 0 {
			slot.readable = true;
			wakers.push(slot.read_waker.take());
		}
		if events & (GLOWCAP_IROH_EV_WRITABLE | GLOWCAP_IROH_EV_CLOSED) != 0 {
			slot.writable = true;
			wakers.push(slot.write_waker.take());
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::sync::Arc;
	use std::task::Wake;

	struct CountWake(Arc<AtomicUsize>);

	impl Wake for CountWake {
		fn wake(self: Arc<Self>) {
			self.0.fetch_add(1, Ordering::Relaxed);
		}
	}

	fn count_waker(count: &Arc<AtomicUsize>) -> Waker {
		Waker::from(Arc::new(CountWake(Arc::clone(count))))
	}

	#[test]
	fn unregister_wakes_read_and_write_waiters() {
		let count = Arc::new(AtomicUsize::new(0));
		let mut state = LoopState::default();
		state.conns.insert(
			7,
			ConnSlot {
				read_waker: Some(count_waker(&count)),
				write_waker: Some(count_waker(&count)),
				..ConnSlot::default()
			},
		);

		remove_conn_wakers(&mut state, 7).wake_all();

		assert_eq!(count.load(Ordering::Relaxed), 2);
		assert!(!state.conns.contains_key(&7));
	}

	#[test]
	fn dispatch_wakes_read_and_write_waiters() {
		let count = Arc::new(AtomicUsize::new(0));
		let mut state = LoopState::default();
		state.conns.insert(
			9,
			ConnSlot {
				read_waker: Some(count_waker(&count)),
				write_waker: Some(count_waker(&count)),
				..ConnSlot::default()
			},
		);

		let mut wakers = ReadyWakers::default();
		dispatch(
			&mut state,
			9,
			GLOWCAP_IROH_EV_READABLE | GLOWCAP_IROH_EV_WRITABLE,
			&mut wakers,
		);

		assert_eq!(count.load(Ordering::Relaxed), 0);
		let slot = state.conns.get(&9).expect("registered conn");
		assert!(slot.readable);
		assert!(slot.writable);
		assert!(slot.read_waker.is_none());
		assert!(slot.write_waker.is_none());

		wakers.wake_all();
		assert_eq!(count.load(Ordering::Relaxed), 2);
	}
}
