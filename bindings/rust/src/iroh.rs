//! iroh transport for the async surface (the `iroh` feature).
//!
//! iroh's encrypted-QUIC netlayer links the Rust sidecar, which ADR-0055 keeps
//! out of the pure-Zig archives; it ships as its own optional companion library,
//! `libpancake_net_transport_iroh`, built with `zig build iroh-abi` (needs cargo). It exports
//! only the `pancake_iroh_*` family, so the `iroh` cargo feature links it
//! *alongside* the static core archives (core symbols come from there) and exposes a
//! dialer/listener here.
//!
//! The frame unit is identical to TCP's — one codec-self-delimited CapTP
//! message — so the [`Connection`](crate::Connection) driver is unchanged: it
//! drives the same sans-io peer over a byte stream. [`IrohStream`] is that byte
//! stream, sourcing inbound bytes through the sidecar's non-blocking `try_read`
//! and sending outbound bytes through `try_write`. Both ride the netlayer's one
//! I/O model (ADR-0057): the endpoint exposes a single readiness fd, and
//! [`IrohLoop`] registers it with tokio (`AsyncFd`) and, when it signals, drains
//! the readiness records and wakes the parked `poll_read`/`poll_write`. One
//! reactor multiplexes every connection — no thread per connection, no parked
//! blocking read.

use core::ffi::c_uint;
use std::collections::HashMap;
use std::future::Future;
use std::io;
use std::os::fd::{BorrowedFd, OwnedFd, RawFd};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};

use tokio::io::unix::AsyncFd;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::Notify;

use crate::sys::iroh as ffi;
use crate::{sys, Connection, Error, Node, Reachability, Result};

use ffi::{
	PancakeIrohConn, PancakeIrohNetlayer, PancakeIrohReadyEvent, PANCAKE_IROH_EV_ACCEPT,
	PANCAKE_IROH_EV_CLOSED, PANCAKE_IROH_EV_READABLE, PANCAKE_IROH_EV_WRITABLE,
};

// How many readiness records one `drain_ready` call pulls. When the fd signals,
// the loop drains in a batch and re-drains until a short count, so a queue deeper
// than the cap is never stranded.
const DRAIN_READY_CAP: usize = 64;

// Like the core `check`, but for `pancake_iroh_*` calls: snapshot the iroh
// transport's own thread-local last-error rather than the unrelated
// ocapn-family one. A `pancake_iroh_*` call that returns PANCAKE_ERR_IO records
// its concrete cause in this slot.
fn check_iroh(code: i32) -> Result<()> {
	if code == sys::OK {
		Ok(())
	} else {
		Err(Error::with_transport_detail(code, iroh_last_error()))
	}
}

/// The calling thread's last error message from the iroh transport archive
/// (`libpancake_net_transport_iroh`), or `None` if none is set. The transport
/// keeps its own thread-local slot, so an iroh call's diagnostic is read here
/// and never from the ocapn family's [`last_error`](crate::last_error).
fn iroh_last_error() -> Option<String> {
	let len = unsafe { ffi::pancake_iroh_last_error(core::ptr::null_mut(), 0) };
	if len == 0 {
		return None;
	}
	let mut buf = vec![0u8; len + 1];
	let written = unsafe { ffi::pancake_iroh_last_error(buf.as_mut_ptr(), buf.len()) };
	buf.truncate(written.min(buf.len()));
	Some(String::from_utf8_lossy(&buf).into_owned())
}

// The raw netlayer handle, released exactly once when the last owner drops. It
// is shared (behind an `Arc`) between the public `IrohNetlayer`/`IrohServer` and
// the readiness loop's dispatcher task, so the endpoint is released only after
// *both* are done with it, the dispatcher can never call `drain_ready` on a
// freed endpoint, regardless of drop order.
struct NetlayerRaw(*mut PancakeIrohNetlayer);

// The pointer is touched by one owner at a time (the public handle's accessors,
// or the dispatcher's drain), never aliased into a concurrent dereference; the
// `Arc` only keeps it alive and addresses it by value across threads.
unsafe impl Send for NetlayerRaw {}
unsafe impl Sync for NetlayerRaw {}

impl Drop for NetlayerRaw {
	fn drop(&mut self) {
		unsafe { ffi::pancake_iroh_netlayer_release(self.0) };
	}
}

/// A bound iroh QUIC endpoint plus the sidecar runtime driving it, the iroh
/// sibling of [`Netlayer`](crate::Netlayer). Dial with
/// [`IrohNetlayer::connect_owned`] or host with [`IrohServer`]. Released on drop,
/// after every connection minted from it is released.
pub struct IrohNetlayer {
	raw: Arc<NetlayerRaw>,
	reachability: Reachability,
}

impl IrohNetlayer {
	/// Bind an iroh endpoint with a fresh random Ed25519 key and the caller's
	/// chosen [`Reachability`], the mandatory posture deciding whether the
	/// endpoint uses relays or a discovery service. There is no default. Binds
	/// the endpoint and arms its readiness loop.
	pub fn new(reachability: Reachability) -> Result<IrohNetlayer> {
		let mut raw: *mut PancakeIrohNetlayer = core::ptr::null_mut();
		check_iroh(unsafe {
			ffi::pancake_iroh_netlayer_new(core::ptr::null(), 0, reachability as c_uint, &mut raw)
		})?;
		Ok(IrohNetlayer {
			raw: Arc::new(NetlayerRaw(raw)),
			reachability,
		})
	}

	/// This endpoint's id, its Ed25519 public key as lowercase hex, the dialable
	/// designator and the URI host.
	pub fn node_id(&self) -> Result<String> {
		let mut buf = [0u8; 64];
		let mut len: usize = 0;
		check_iroh(unsafe {
			ffi::pancake_iroh_netlayer_node_id(self.raw.0, buf.as_mut_ptr(), buf.len(), &mut len)
		})?;
		Ok(String::from_utf8_lossy(&buf[..len]).into_owned())
	}

	/// This endpoint's comma-separated direct socket addresses, the hint string a
	/// partner passes to dial it relay-less.
	pub fn direct_addresses(&self) -> Result<String> {
		// The endpoint with no direct addresses writes zero bytes; a buffer too
		// small is ERR_INVALID_ARGUMENT, so grow until it fits.
		let mut cap = 256usize;
		loop {
			let mut buf = vec![0u8; cap];
			let mut len: usize = 0;
			let code = unsafe {
				ffi::pancake_iroh_netlayer_direct_addrs(
					self.raw.0,
					buf.as_mut_ptr(),
					buf.len(),
					&mut len,
				)
			};
			if code == sys::ERR_INVALID_ARGUMENT && cap < 64 * 1024 {
				cap *= 4;
				continue;
			}
			check_iroh(code)?;
			return Ok(String::from_utf8_lossy(&buf[..len]).into_owned());
		}
	}

	/// Close the endpoint without releasing the handle: later dials fail and the
	/// readiness loop winds down. Idempotent, the shutdown lever a dropped dialer
	/// or server pulls.
	pub fn close(&self) {
		unsafe { ffi::pancake_iroh_netlayer_close(self.raw.0) };
	}

	/// Dial a partner by endpoint id and direct-address hints over the
	/// event-driven loop surface (ADR-0057), returning the byte stream that
	/// carries the OCapN session. The dial itself blocks (run on a blocking-pool
	/// thread); the connection's frame I/O is then non-blocking, driven by the
	/// stream's own readiness loop. The returned stream owns this netlayer's
	/// lifetime (an ephemeral dialing endpoint released with the connection).
	pub async fn connect_owned(self, node_id: &str, direct_addresses: &str) -> Result<IrohStream> {
		let iloop = IrohLoop::start(Arc::clone(&self.raw))?;
		let raw = self.raw.0 as usize;
		// A posture that resolves by id through a propagating discovery service
		// (`Discovery` and `DiscoveryNoRelay`) can fail a dial-by-id with "no
		// addressing information" until the exporter's pkarr record propagates
		// (seconds, variable), so retry the dial on a bounded budget; every other
		// posture dials once (Direct's addresses are in hand, LocalDiscovery
		// resolves instantly). Mirrors the TS `dialResolving` and the Zig
		// `iroh-reachability` driver.
		let conn = match dial_resolving(
			raw,
			node_id,
			direct_addresses,
			matches!(
				self.reachability,
				Reachability::Discovery | Reachability::DiscoveryNoRelay
			),
		)
		.await
		{
			Ok(conn) => conn,
			Err(e) => {
				iloop.shutdown();
				return Err(e);
			}
		};
		iloop.register(conn);
		Ok(IrohStream::new(
			conn as *mut PancakeIrohConn,
			iloop,
			Some(self),
			true,
		))
	}
}

// The discovery-posture dial retry budget: how long pkarr propagation is given
// before each retry, and how many attempts (~72s total, covering n0 DNS/pkarr
// propagation). Matches the TS `dialResolving` budget.
const DISCOVERY_DIAL_RETRY_MS: u64 = 3_000;
const DISCOVERY_DIAL_MAX_ATTEMPTS: u32 = 24;

// Dial, retrying only under a propagating-discovery posture while it resolves the
// partner by id. A dial-stage error (the sidecar's "no addressing information"
// during pkarr propagation) is retried on the budget; every other posture, and a
// spawn join failure, surfaces immediately. Mirrors TS `dialResolving`.
async fn dial_resolving(raw: usize, node_id: &str, hints: &str, retry: bool) -> Result<usize> {
	let mut attempt: u32 = 1;
	loop {
		let nid = node_id.to_string();
		let h = hints.to_string();
		match tokio::task::spawn_blocking(move || {
			try_dial(raw as *mut PancakeIrohNetlayer, &nid, &h)
		})
		.await
		{
			Ok(Ok(conn)) => return Ok(conn),
			Ok(Err(e)) => {
				if !retry || attempt >= DISCOVERY_DIAL_MAX_ATTEMPTS {
					return Err(e);
				}
			}
			Err(_) => return Err(Error::from_code(sys::ERR_IO)),
		}
		attempt += 1;
		tokio::time::sleep(std::time::Duration::from_millis(DISCOVERY_DIAL_RETRY_MS)).await;
	}
}

// Non-blocking-loop dial, run on a blocking-pool thread (the dial handshake
// itself blocks; the connection's frame I/O is then non-blocking). Returns the
// connection pointer as a usize so the `spawn_blocking` join value stays `Send`.
fn try_dial(netlayer: *mut PancakeIrohNetlayer, node_id: &str, hints: &str) -> Result<usize> {
	let mut conn: *mut PancakeIrohConn = core::ptr::null_mut();
	check_iroh(unsafe {
		ffi::pancake_iroh_netlayer_try_connect(
			netlayer,
			node_id.as_ptr(),
			node_id.len(),
			hints.as_ptr(),
			hints.len(),
			&mut conn,
		)
	})?;
	Ok(conn as usize)
}

// One iroh connection pointer, released exactly once — when the owning
// `IrohStream` drops. No sidecar call ever parks on the connection (the loop's
// only blocking call touches the endpoint), so releasing it never races a parked
// read — the teardown hazard the thread-per-connection path had.
struct ConnPtr(*mut PancakeIrohConn);

// The pointer is single-owner (one `IrohStream`); it is held behind an `Arc` only
// so the readiness loop can address the connection by its handle value, never
// dereferenced from another thread.
unsafe impl Send for ConnPtr {}
unsafe impl Sync for ConnPtr {}

impl Drop for ConnPtr {
	fn drop(&mut self) {
		unsafe { ffi::pancake_iroh_conn_release(self.0) };
	}
}

// Per-connection readiness state. A loop connection is single-owner (one task
// drives it), so at most one task waits to read and one to write; a `*_ready`
// flag holds an edge that arrived before its waiter so no wakeup is lost.
#[derive(Default)]
struct ConnSlot {
	read_waker: Option<Waker>,
	write_waker: Option<Waker>,
	readable: bool,
	writable: bool,
	closed: bool,
}

#[derive(Default)]
struct LoopState {
	conns: HashMap<usize, ConnSlot>,
	accept_waker: Option<Waker>,
	accept_pending: usize,
	closed: bool,
}

/// The per-netlayer readiness dispatcher for the iroh loop surface (ADR-0057).
///
/// It registers the netlayer's single readiness fd with tokio's reactor (an
/// [`AsyncFd`] over a dup of the fd) and, when the fd signals, drains the pending
/// readiness records and wakes the task (a `poll_read`/`poll_write`, or an
/// accept) waiting on each. Everything runs on one reactor task — no thread per
/// connection — and because the drain touches only the endpoint, never a
/// per-connection buffer, a connection can be released at any time without racing
/// a read. `shutdown` stops the task and wakes every waiter; the netlayer (shared
/// behind an `Arc`) is released only once both the public handle and this task
/// have dropped, so the drain can never touch a freed endpoint. This is the Rust
/// sibling of the Deno binding's `IrohLoop` and the Zig resident's `LoopHost`:
/// one reactor multiplexes many connections.
pub(crate) struct IrohLoop {
	netlayer: Arc<NetlayerRaw>,
	state: Mutex<LoopState>,
	task: Mutex<Option<tokio::task::JoinHandle<()>>>,
	stop: AtomicBool,
	notify: Notify,
}

impl IrohLoop {
	/// Register the netlayer's readiness fd with the reactor and spawn the single
	/// dispatcher task. The loop is already armed (the netlayer arms it at
	/// construction), so this only stands up the reactor side.
	fn start(netlayer: Arc<NetlayerRaw>) -> Result<Arc<IrohLoop>> {
		let raw_fd: RawFd = unsafe { ffi::pancake_iroh_netlayer_readiness_fd(netlayer.0) };
		if raw_fd < 0 {
			return Err(Error::with_transport_detail(sys::ERR_IO, iroh_last_error()));
		}
		// Dup the borrowed fd so the `AsyncFd` owns and closes its own copy on
		// drop, never the netlayer's fd. The dup shares the same socket, so its
		// readiness tracks the original and `drain_ready` (which reads the
		// original) clears both.
		let owned: OwnedFd = unsafe { BorrowedFd::borrow_raw(raw_fd) }
			.try_clone_to_owned()
			.map_err(|_| Error::from_code(sys::ERR_IO))?;
		let iloop = Arc::new(IrohLoop {
			netlayer,
			state: Mutex::new(LoopState::default()),
			task: Mutex::new(None),
			stop: AtomicBool::new(false),
			notify: Notify::new(),
		});
		let runner = Arc::clone(&iloop);
		let handle = tokio::spawn(async move {
			match AsyncFd::new(owned) {
				Ok(afd) => runner.run(afd).await,
				Err(_) => runner.wake_all_closed(),
			}
		});
		*iloop.task.lock().unwrap() = Some(handle);
		Ok(iloop)
	}

	fn register(&self, key: usize) {
		self.state
			.lock()
			.unwrap()
			.conns
			.insert(key, ConnSlot::default());
	}

	fn unregister(&self, key: usize) {
		let waker = {
			let mut st = self.state.lock().unwrap();
			st.conns
				.remove(&key)
				.and_then(|mut slot| slot.read_waker.take().or_else(|| slot.write_waker.take()))
		};
		if let Some(w) = waker {
			w.wake();
		}
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
						self.drain();
						// `drain_ready` consumed the fd's wakeup bytes, so clear
						// the reactor's readiness and await a fresh edge.
						g.clear_ready();
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
		let nl = self.netlayer.0;
		let mut buf = [PancakeIrohReadyEvent {
			conn: core::ptr::null_mut(),
			events: 0,
		}; DRAIN_READY_CAP];
		loop {
			let n = unsafe {
				ffi::pancake_iroh_netlayer_drain_ready(nl, buf.as_mut_ptr(), DRAIN_READY_CAP)
			};
			if n <= 0 {
				break;
			}
			let mut wakers: Vec<Waker> = Vec::new();
			{
				let mut st = self.state.lock().unwrap();
				for ev in buf.iter().take(n as usize) {
					dispatch(&mut st, ev.conn as usize, ev.events, &mut wakers);
				}
			}
			for w in wakers {
				w.wake();
			}
			if (n as usize) < DRAIN_READY_CAP {
				break;
			}
		}
	}

	fn wake_all_closed(&self) {
		let mut wakers: Vec<Waker> = Vec::new();
		{
			let mut st = self.state.lock().unwrap();
			st.closed = true;
			if let Some(w) = st.accept_waker.take() {
				wakers.push(w);
			}
			for slot in st.conns.values_mut() {
				slot.closed = true;
				wakers.extend(slot.read_waker.take());
				wakers.extend(slot.write_waker.take());
			}
		}
		for w in wakers {
			w.wake();
		}
	}

	/// Stop the loop and wake every waiter so parked pumps unwind. Idempotent.
	/// Signals the dispatcher to stop, wakes it off its `readable` await, and
	/// aborts the task as a backstop. The abort only takes effect at an await
	/// point, never mid-`drain`, and the netlayer's `Arc` outlives the task, so a
	/// freed endpoint is never drained.
	fn shutdown(&self) {
		self.stop.store(true, Ordering::Release);
		self.wake_all_closed();
		self.notify.notify_waiters();
		if let Some(h) = self.task.lock().unwrap().take() {
			h.abort();
		}
	}
}

// Route one readiness record to its waiter (collected, woken after the lock is
// released). An accept record carries a null connection.
fn dispatch(st: &mut LoopState, conn_key: usize, events: u32, wakers: &mut Vec<Waker>) {
	if events & PANCAKE_IROH_EV_ACCEPT != 0 {
		// Record the pending accept first, then wake any waiter, the woken
		// `AcceptReady` re-polls and observes the pending count, so the signal is
		// never lost to a wake that races the re-registration.
		st.accept_pending += 1;
		if let Some(w) = st.accept_waker.take() {
			wakers.push(w);
		}
		return;
	}
	if let Some(slot) = st.conns.get_mut(&conn_key) {
		if events & PANCAKE_IROH_EV_CLOSED != 0 {
			slot.closed = true;
		}
		if events & (PANCAKE_IROH_EV_READABLE | PANCAKE_IROH_EV_CLOSED) != 0 {
			slot.readable = true;
			wakers.extend(slot.read_waker.take());
		}
		if events & (PANCAKE_IROH_EV_WRITABLE | PANCAKE_IROH_EV_CLOSED) != 0 {
			slot.writable = true;
			wakers.extend(slot.write_waker.take());
		}
	}
}

/// A byte stream over one iroh QUIC connection: the iroh sibling of a
/// `TcpStream` for the [`Connection`](crate::Connection) driver. Inbound bytes
/// come from the sidecar's non-blocking `try_read`; the peer re-frames them.
/// Outbound bytes go through `try_write`, re-arming on the next writable record
/// when the sidecar buffer is full. Its readiness loop, not a parked blocking
/// read, decides when bytes move. Dropping it tears the connection down: a dialer
/// (`owns_loop`) stops its own loop and releases its ephemeral endpoint; an
/// accepted stream just leaves the server's loop and releases its connection.
pub struct IrohStream {
	conn: Arc<ConnPtr>,
	key: usize,
	iloop: Arc<IrohLoop>,
	owns_loop: bool,
	// A dialer's ephemeral endpoint, held only so it is released (by its `Drop`)
	// after this stream's loop and connection are torn down.
	owned_netlayer: Option<IrohNetlayer>,
}

impl IrohStream {
	fn new(
		conn: *mut PancakeIrohConn,
		iloop: Arc<IrohLoop>,
		owned_netlayer: Option<IrohNetlayer>,
		owns_loop: bool,
	) -> IrohStream {
		IrohStream {
			conn: Arc::new(ConnPtr(conn)),
			key: conn as usize,
			iloop,
			owns_loop,
			owned_netlayer,
		}
	}

	/// Dial an iroh partner by endpoint id and direct-address hints, returning the
	/// byte stream the [`Connection`](crate::Connection) driver carries the
	/// session over. The local endpoint is ephemeral, created with the caller's
	/// chosen [`Reachability`] (no default), and released with the stream.
	pub async fn connect(
		node_id: &str,
		direct_addresses: &str,
		reachability: Reachability,
	) -> Result<IrohStream> {
		let netlayer = IrohNetlayer::new(reachability)?;
		netlayer.connect_owned(node_id, direct_addresses).await
	}
}

impl Drop for IrohStream {
	fn drop(&mut self) {
		if self.owns_loop {
			// The dialer owns the loop and netlayer: stop the dispatcher so it
			// wakes its waiters and drops its netlayer `Arc`. The endpoint is
			// released once both this stream and the task have dropped their Arc.
			self.iloop.shutdown();
		} else {
			// An accepted stream borrows the server's loop: just drop the routing
			// entry so no later record resolves a waiter on this connection.
			self.iloop.unregister(self.key);
		}
		drop(self.owned_netlayer.take());
	}
}

impl AsyncRead for IrohStream {
	fn poll_read(
		self: Pin<&mut Self>,
		cx: &mut Context<'_>,
		buf: &mut ReadBuf<'_>,
	) -> Poll<io::Result<()>> {
		let me = self.get_mut();
		loop {
			let dst = buf.initialize_unfilled();
			if dst.is_empty() {
				return Poll::Ready(Ok(())); // the caller's buffer is full
			}
			let n =
				unsafe { ffi::pancake_iroh_conn_try_read(me.conn.0, dst.as_mut_ptr(), dst.len()) };
			if n == sys::WOULD_BLOCK as isize {
				// Nothing buffered yet: park on this connection's readiness. A
				// missing/closed slot means the connection was torn down, a clean
				// EOF (zero bytes filled).
				let mut st = me.iloop.state.lock().unwrap();
				match st.conns.get_mut(&me.key) {
					None => return Poll::Ready(Ok(())),
					Some(slot) if slot.closed => return Poll::Ready(Ok(())),
					Some(slot) if slot.readable => {
						slot.readable = false;
						continue; // an edge arrived first; re-read before parking
					}
					Some(slot) => {
						slot.read_waker = Some(cx.waker().clone());
						return Poll::Pending;
					}
				}
			}
			if n == sys::ERR_CLOSED as isize {
				return Poll::Ready(Ok(())); // clean end of stream
			}
			if n < 0 {
				return Poll::Ready(Err(io::Error::other(format!(
					"iroh try_read failed (code {n})"
				))));
			}
			buf.advance(n as usize);
			return Poll::Ready(Ok(()));
		}
	}
}

impl AsyncWrite for IrohStream {
	fn poll_write(
		self: Pin<&mut Self>,
		cx: &mut Context<'_>,
		src: &[u8],
	) -> Poll<io::Result<usize>> {
		let me = self.get_mut();
		if src.is_empty() {
			return Poll::Ready(Ok(0));
		}
		loop {
			let n = unsafe { ffi::pancake_iroh_conn_try_write(me.conn.0, src.as_ptr(), src.len()) };
			if n == sys::WOULD_BLOCK as isize {
				// The sidecar buffer is full: park on writability and retry the
				// same bytes after the next writable record.
				let mut st = me.iloop.state.lock().unwrap();
				match st.conns.get_mut(&me.key) {
					None => {
						return Poll::Ready(Err(io::Error::new(
							io::ErrorKind::BrokenPipe,
							"iroh connection closed",
						)))
					}
					Some(slot) if slot.closed => {
						return Poll::Ready(Err(io::Error::new(
							io::ErrorKind::BrokenPipe,
							"iroh connection closed",
						)))
					}
					Some(slot) if slot.writable => {
						slot.writable = false;
						continue;
					}
					Some(slot) => {
						slot.write_waker = Some(cx.waker().clone());
						return Poll::Pending;
					}
				}
			}
			if n < 0 {
				return Poll::Ready(Err(io::Error::other(format!(
					"iroh try_write failed (code {n})"
				))));
			}
			// try_write is all-or-nothing: the whole slice went.
			return Poll::Ready(Ok(n as usize));
		}
	}

	fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
		// Writes go straight to the sidecar in `poll_write`; nothing is buffered
		// here to flush.
		Poll::Ready(Ok(()))
	}

	fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
		Poll::Ready(Ok(()))
	}
}

/// A listening iroh endpoint — the iroh sibling of [`Server`](crate::Server).
/// [`IrohServer::accept`] yields one ready [`Connection`] per partner, completing
/// the responder handshake; read [`IrohServer::uri`] for the dialable address to
/// hand a client. Build one with [`listen_iroh`]. Needs the iroh ABI library
/// (`zig build iroh-abi`).
pub struct IrohServer {
	netlayer: IrohNetlayer,
	node_id: String,
	// One readiness loop serves every accepted connection from one thread
	// (ADR-0057), instead of a blocking accept and a read parked per connection.
	iloop: Arc<IrohLoop>,
	// Every accepted connection shares this node `Node` — its one retained
	// identity and gift registry — exactly as the TCP [`Server`](crate::Server)
	// does, so a node both serves recipients (accept) and dials the exporter it
	// re-gifts from under one identity (the gifter half of a three-party handoff,
	// ADR-0009).
	node: Node,
}

impl IrohServer {
	/// Bind an iroh endpoint with a fresh random Ed25519 key and the caller's
	/// chosen [`Reachability`], the mandatory posture, no default.
	pub fn bind(reachability: Reachability) -> Result<IrohServer> {
		let netlayer = IrohNetlayer::new(reachability)?;
		let node_id = netlayer.node_id()?;
		let iloop = IrohLoop::start(Arc::clone(&netlayer.raw))?;
		Ok(IrohServer {
			netlayer,
			node_id,
			iloop,
			node: Node::new_node(),
		})
	}

	/// The node every accepted connection shares, its retained identity
	/// and gift registry. Pass it to
	/// [`Connection::connect_iroh_with_node`] to dial the exporter this node
	/// re-gifts from under one identity (the gifter half of a three-party
	/// handoff), and publish a node-giftable on it with
	/// [`Node::publish_giftable`].
	pub fn node(&self) -> Node {
		self.node.clone()
	}

	/// This endpoint's id, the keyed locator designator and the URI host.
	pub fn node_id(&self) -> &str {
		&self.node_id
	}

	/// This endpoint's comma-separated direct-address hints.
	pub fn direct_addresses(&self) -> Result<String> {
		self.netlayer.direct_addresses()
	}

	/// The `ocapn://<nodeid>.iroh?direct-addresses=…` URI a partner dials,
	/// rendered through the core locator grammar.
	pub fn uri(&self) -> Result<String> {
		let mut hints = std::collections::BTreeMap::new();
		let addrs = self.direct_addresses()?;
		if !addrs.is_empty() {
			hints.insert("direct-addresses".to_string(), addrs);
		}
		crate::uri::format_peer_uri("iroh", &self.node_id, &hints)
	}

	/// Accept the next partner as a ready [`Connection`], completing the responder
	/// handshake and signing this endpoint's id as the locator designator. The
	/// driver carries the peer over the accepted byte stream exactly as over TCP.
	pub async fn accept(&self) -> Result<Connection> {
		let node_id = self.node_id().to_string();
		let stream = self.accept_stream().await?;
		Ok(Connection::over_shared(
			stream,
			"iroh",
			node_id,
			self.node.clone(),
		))
	}

	/// Wait (on the readiness loop, never a parked thread) for the next dial and
	/// return the accepted byte stream. The accepted stream shares this server's
	/// loop and releases only its own connection when it drops; the server's
	/// endpoint stays open for the next accept.
	async fn accept_stream(&self) -> Result<IrohStream> {
		loop {
			let mut conn: *mut PancakeIrohConn = core::ptr::null_mut();
			let code =
				unsafe { ffi::pancake_iroh_netlayer_try_accept(self.netlayer.raw.0, &mut conn) };
			if code == sys::OK {
				self.iloop.register(conn as usize);
				return Ok(IrohStream::new(conn, Arc::clone(&self.iloop), None, false));
			}
			if code != sys::WOULD_BLOCK {
				return Err(Error::with_transport_detail(code, iroh_last_error()));
			}
			// Nothing pending: park on the loop's next accept record. A `false`
			// resolution means the server is closing.
			if !(AcceptReady { iloop: &self.iloop }).await {
				return Err(Error::from_code(sys::ERR_CLOSED));
			}
		}
	}

	/// Stop accepting and release the endpoint: close it and stop the readiness
	/// loop. The endpoint is released once both the server and the dispatcher
	/// task have dropped their shared netlayer handle.
	pub fn close(&self) {
		self.netlayer.close();
		self.iloop.shutdown();
	}
}

impl Drop for IrohServer {
	fn drop(&mut self) {
		// Stop the dispatcher so it wakes its waiters and drops its netlayer
		// `Arc`; the endpoint is released when the last `Arc` (this server's or
		// the task's) drops, so the drain never touches a freed endpoint.
		self.iloop.shutdown();
	}
}

/// A future that resolves `true` when the server's loop reports an acceptable
/// connection, or `false` when the loop closes.
struct AcceptReady<'a> {
	iloop: &'a IrohLoop,
}

impl Future for AcceptReady<'_> {
	type Output = bool;

	fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<bool> {
		let mut st = self.iloop.state.lock().unwrap();
		if st.closed {
			return Poll::Ready(false);
		}
		if st.accept_pending > 0 {
			st.accept_pending -= 1;
			return Poll::Ready(true);
		}
		st.accept_waker = Some(cx.waker().clone());
		Poll::Pending
	}
}

// ── the iroh application surface ──────────────────────────────────────────────
// The same [`Connection`] surface over iroh's encrypted QUIC: the one
// [`connect`](crate::connect) dialer routes an `ocapn://<nodeid>.iroh?…` locator
// to `Connection::connect_iroh` here, and [`listen_iroh`]/[`IrohServer`] host. The
// driver is unchanged — `Connection::over` carries the peer over the iroh
// byte-stream bridge ([`IrohStream`]) exactly as over a `TcpStream`; only the
// signed locator differs (`iroh` + endpoint id, never `tcp` + host:port). The
// iroh-touching code lives here behind the `iroh` feature, so a tcp-only build
// references no iroh symbol — the same `libpancake_ocapn` /
// `libpancake_net_transport_iroh` split the other bindings mirror.

impl Connection {
	/// The iroh dial mechanism behind [`connect`]: take an endpoint id and
	/// direct-address hints, complete the keyed OCapN handshake over the
	/// encrypted-QUIC transport, and return a ready connection. The local
	/// endpoint is ephemeral (a fresh key), created with the caller's chosen
	/// `reachability`, and released with the connection. Needs the iroh ABI
	/// library (`zig build iroh-abi`).
	pub async fn connect_iroh(
		node_id: &str,
		direct_addresses: &str,
		reachability: Reachability,
	) -> Result<Connection> {
		let stream = IrohStream::connect(node_id, direct_addresses, reachability).await?;
		// A dialer signs an empty designator (its identity is the session key),
		// matching the Zig driver and the other bindings.
		Ok(Connection::over(stream, "iroh", String::new()))
	}

	/// The node-keyed iroh dial behind a handoff redeem: dial the exporter
	/// endpoint and bring the connection up under `node` rather than a fresh
	/// node, so the redeemed capability and any further handoff it triggers share
	/// the recipient's one identity and gift registry (ADR-0009/ADR-0056), the
	/// iroh sibling of the TCP [`Connection::connect_with_node`]. Needs the
	/// iroh ABI library (`zig build iroh-abi`).
	pub async fn connect_iroh_with_node(
		node_id: &str,
		direct_addresses: &str,
		reachability: Reachability,
		node: Node,
	) -> Result<Connection> {
		let stream = IrohStream::connect(node_id, direct_addresses, reachability).await?;
		Ok(Connection::over_shared(stream, "iroh", String::new(), node))
	}
}

/// Bind an iroh endpoint and return an [`IrohServer`] to accept partners on, the
/// iroh sibling of [`listen`](crate::listen). `reachability` is the mandatory
/// posture (no default). Needs the iroh ABI library (`zig build iroh-abi`).
pub fn listen_iroh(reachability: Reachability) -> Result<IrohServer> {
	IrohServer::bind(reachability)
}
