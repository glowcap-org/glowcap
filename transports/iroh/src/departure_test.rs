//! A partner that departs while the host holds its reads behind a refused
//! write: the host's retry is accepted, and the reader still delivers every
//! byte the stack held, in order, before it reports the end.

use crate::lifecycle_test::{drain_ready_records, set_nonblocking, try_write};
use crate::tests::{direct_endpoint, free_endpoint};
use crate::{
	EV_CLOSED, EV_READABLE, EV_WRITABLE, GlowcapIrohConn, GlowcapIrohEndpoint, NB_BUFFER_BOUND, NB_STEADY_BYTES,
	WOULD_BLOCK,
};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

const WAIT: Duration = Duration::from_secs(10);
const STEP: Duration = Duration::from_millis(10);

/// Byte `i` of the partner's counting stream: the little-endian index of the
/// four-byte word it falls in, so a gap, repeat, or reorder shows at its offset.
fn pattern_byte(i: usize) -> u8 {
	((i / 4) as u32).to_le_bytes()[i % 4]
}

fn pattern(range: std::ops::Range<usize>) -> Vec<u8> {
	range.map(pattern_byte).collect()
}

/// The host's end (`client`, non-blocking) and the partner's end (`server`).
struct Pair {
	client: Box<GlowcapIrohEndpoint>,
	server: Box<GlowcapIrohEndpoint>,
	conn: *mut GlowcapIrohConn,
	partner: crate::Connection,
	partner_send: Option<crate::SendStream>,
	partner_recv: Option<crate::RecvStream>,
}

fn pair() -> Pair {
	use crate::{ALPN, AcceptedRaw, make_conn};

	let client = direct_endpoint(5_000);
	let server = direct_endpoint(5_000);
	let (raw, partner, partner_send, partner_recv) = client.rt.block_on(async {
		let (dialed, accepted) = tokio::join!(client.ep.connect(server.ep.addr(), ALPN), async {
			server.ep.accept().await.unwrap().await.unwrap()
		});
		let dialed = dialed.unwrap();
		let (mut send, recv) = dialed.open_bi().await.unwrap();
		// A stream is visible to its partner only once bytes cross it.
		send.write_all(b"open").await.unwrap();
		let (partner_send, partner_recv) = accepted.accept_bi().await.unwrap();
		(
			AcceptedRaw {
				conn: dialed,
				send,
				recv,
			},
			accepted,
			partner_send,
			partner_recv,
		)
	});
	let conn = make_conn(&client, raw).unwrap();
	assert_eq!(set_nonblocking(&client, conn), 0);
	Pair {
		client,
		server,
		conn,
		partner,
		partner_send: Some(partner_send),
		partner_recv: Some(partner_recv),
	}
}

fn release(pair: Pair, partner_tasks: Vec<tokio::task::JoinHandle<()>>) {
	// SAFETY: `conn` is the owned handle `make_conn` returned and is not used after this call.
	unsafe { crate::conn::glowcap_iroh_sidecar_conn_free(pair.conn) };
	for task in partner_tasks {
		// tolerant: a partner task that panicked already failed the test through its own assertion.
		let _ = pair.server.rt.block_on(task);
	}
	drop((pair.partner, pair.partner_send, pair.partner_recv));
	assert_eq!(free_endpoint(pair.client), 0);
	assert_eq!(free_endpoint(pair.server), 0);
}

fn conn_id(conn: *mut GlowcapIrohConn) -> usize {
	// SAFETY: `conn` is the live handle `make_conn` returned.
	unsafe { crate::nonblocking::calls::glowcap_iroh_sidecar_conn_id(conn) }
}

fn inbound_pending(conn: *mut GlowcapIrohConn) -> usize {
	// SAFETY: `conn` is the live handle `make_conn` returned, freed only after the test body.
	let conn = unsafe { &*conn };
	conn.nb.get().unwrap().inbound_pending()
}

/// The outbound state a test reads under the lock.
struct OutboundState {
	/// The batch the writer holds in flight.
	in_flight: usize,
	/// The bytes queued behind that batch.
	queued: usize,
	/// The queue's storage capacity.
	capacity: usize,
	/// Whether the writer has observed the partner's departure.
	stopped: bool,
}

impl OutboundState {
	fn pending(&self) -> usize {
		self.in_flight + self.queued
	}
}

fn outbound_state(conn: *mut GlowcapIrohConn) -> OutboundState {
	// SAFETY: `conn` is the live handle `make_conn` returned, freed only after the test body.
	let conn = unsafe { &*conn };
	let out = conn.nb.get().unwrap().outbound.lock().unwrap();
	OutboundState {
		in_flight: out.in_flight,
		queued: out.buf.len(),
		capacity: out.buf.capacity(),
		stopped: out.partner_stopped,
	}
}

fn try_read(conn: *mut GlowcapIrohConn, buf: &mut [u8]) -> isize {
	// SAFETY: `conn` is a live handle and `buf` is a writable local slice of the length passed.
	unsafe { crate::nonblocking::calls::glowcap_iroh_sidecar_conn_try_read(conn, buf.as_mut_ptr(), buf.len()) }
}

/// The readiness records for one connection, accumulated across drains.
struct Records {
	events: Vec<u32>,
}

impl Records {
	fn new() -> Self {
		Records { events: Vec::new() }
	}

	fn drain(&mut self, endpoint: &GlowcapIrohEndpoint, id: usize) {
		for event in drain_ready_records(endpoint) {
			if event.subject != id {
				continue;
			}
			// A bare `EV_CLOSED` tells the host the connection was lost.
			assert!(
				event.events & EV_CLOSED == 0 || event.events & EV_READABLE != 0,
				"a bare EV_CLOSED record arrived: {:#x}",
				event.events
			);
			self.events.push(event.events);
		}
	}

	fn saw(&self, bits: u32) -> bool {
		self.events.iter().any(|events| events & bits == bits)
	}

	fn forget(&mut self) {
		self.events.clear();
	}
}

fn wait_for(what: &str, mut ready: impl FnMut() -> bool) {
	let deadline = Instant::now() + WAIT;
	while !ready() {
		assert!(Instant::now() < deadline, "timed out waiting for {what}");
		std::thread::sleep(STEP);
	}
}

/// How long a chunk may stay queued before the writer counts as held. It
/// stands for "the writer has taken no batch for this long because its batch
/// in flight waits on QUIC flow control", which holds once the partner, who
/// reads nothing, has a full window. A host slower than this bound reaches the
/// fill below with the writer not held, and the callers' precondition fails.
const WRITER_HELD_AFTER: Duration = Duration::from_secs(1);

/// Hold the writer behind a batch in flight, then fill the queue behind it to
/// the bound. Chunks go one at a time and each waits to be taken as the
/// writer's batch, so a batch never exceeds one chunk. The partner reads
/// nothing, so flow control stops the writer: a chunk it does not take within
/// `WRITER_HELD_AFTER` sits in the queue behind the held batch. The fill that
/// follows leaves `NB_BUFFER_BOUND` minus that batch queued.
fn fill_outbound_until_refused(conn: *mut GlowcapIrohConn) {
	let chunk = vec![7u8; 16 * 1024];
	let deadline = Instant::now() + WAIT;
	loop {
		assert!(Instant::now() < deadline, "the writer was never held by flow control");
		assert_eq!(try_write(conn, &chunk), chunk.len() as isize);
		let offered = Instant::now();
		while outbound_state(conn).queued != 0 {
			if offered.elapsed() >= WRITER_HELD_AFTER {
				return fill_to_refusal(conn, &chunk);
			}
			std::thread::sleep(Duration::from_micros(200));
		}
	}
}

/// Write until the refusal holds: the queue is at the bound and stays refused.
fn fill_to_refusal(conn: *mut GlowcapIrohConn, chunk: &[u8]) {
	let mut refused = 0;
	let deadline = Instant::now() + WAIT;
	while refused < 100 {
		assert!(Instant::now() < deadline, "the outbound buffer never held a refusal");
		if try_write(conn, chunk) == WOULD_BLOCK {
			refused += 1;
			std::thread::sleep(STEP);
		} else {
			refused = 0;
		}
	}
}

/// Read the partner's counting stream in order from `from`, calling `each`
/// between reads. Stops after `until` bytes, or at the end of the stream (`0`)
/// when `until` is `None`. Returns the bytes read.
fn read_pattern(
	pair: &Pair,
	records: &mut Records,
	from: usize,
	until: Option<usize>,
	mut each: impl FnMut(),
) -> usize {
	let id = conn_id(pair.conn);
	let mut buf = vec![0u8; 64 * 1024];
	let mut total = 0;
	let deadline = Instant::now() + WAIT;
	while until.is_none_or(|until| total < until) {
		assert!(Instant::now() < deadline, "the stream never delivered its bytes");
		each();
		let n = try_read(pair.conn, &mut buf);
		if n == WOULD_BLOCK {
			records.drain(&pair.client, id);
			std::thread::sleep(STEP);
			continue;
		}
		assert!(n >= 0, "a read failed with {n}");
		if n == 0 {
			break;
		}
		let n = n as usize;
		assert_eq!(
			&buf[..n],
			&pattern(from + total..from + total + n)[..],
			"bytes differ at offset {total}"
		);
		total += n;
	}
	records.drain(&pair.client, id);
	total
}

/// Stream the counting pattern to the host from the partner's send half,
/// publishing the bytes the stream has accepted. The count stops advancing
/// when QUIC flow control holds the stream.
fn stream_pattern(pair: &mut Pair, bytes: usize, finish: bool) -> (Arc<AtomicUsize>, tokio::task::JoinHandle<()>) {
	let accepted = Arc::new(AtomicUsize::new(0));
	let published = accepted.clone();
	let mut send = pair.partner_send.take().unwrap();
	let task = pair.server.rt.spawn(async move {
		let mut offset = 0;
		while offset < bytes {
			let end = (offset + 65536).min(bytes);
			// tolerant: the partner's close ends the stream mid-pattern, which the host's reads then prove.
			if send.write_all(&pattern(offset..end)).await.is_err() {
				return;
			}
			offset = end;
			published.store(offset, Ordering::SeqCst);
		}
		if finish {
			// tolerant: a stream the host already reset has nothing left to finish.
			let _ = send.finish();
		}
	});
	(accepted, task)
}

/// Wait until the stream has accepted more than `NB_BUFFER_BOUND` bytes and has
/// not advanced for a quiet interval: the stream is held by flow control, so the
/// stack's window past the host's buffer is full.
fn wait_for_flow_control_hold(accepted: &AtomicUsize) {
	let quiet = Duration::from_millis(300);
	let mut seen = accepted.load(Ordering::SeqCst);
	let mut since = Instant::now();
	wait_for("the partner's stream to be held by flow control", || {
		let now = accepted.load(Ordering::SeqCst);
		if now != seen {
			seen = now;
			since = Instant::now();
		}
		seen > NB_BUFFER_BOUND && since.elapsed() >= quiet
	});
}

#[test]
fn clean_close_with_a_full_inbound_buffer_retries_the_held_write_then_delivers_every_held_byte() {
	let mut pair = pair();
	let id = conn_id(pair.conn);
	let mut records = Records::new();
	// The partner streams a counting pattern far past the bound, and the host never reads.
	let (accepted, streamer) = stream_pattern(&mut pair, 16 << 20, false);
	wait_for("the inbound buffer to reach its bound", || {
		inbound_pending(pair.conn) == NB_BUFFER_BOUND
	});
	wait_for_flow_control_hold(&accepted);
	assert_eq!(
		inbound_pending(pair.conn),
		NB_BUFFER_BOUND,
		"the parked reader moved bytes"
	);
	fill_outbound_until_refused(pair.conn);
	records.drain(&pair.client, id);
	records.forget();

	pair.partner.close(0u32.into(), b"");
	wait_for("EV_WRITABLE after the partner closed", || {
		records.drain(&pair.client, id);
		records.saw(EV_WRITABLE)
	});
	assert_eq!(
		try_write(pair.conn, b"retry"),
		5,
		"the held write was refused after the partner departed"
	);

	let total = read_pattern(&pair, &mut records, 0, None, || {});
	assert!(
		total > NB_BUFFER_BOUND,
		"only {total} bytes arrived, none past the buffer the stack held"
	);
	wait_for("EV_READABLE | EV_CLOSED", || {
		records.drain(&pair.client, id);
		records.saw(EV_READABLE | EV_CLOSED)
	});
	release(pair, vec![streamer]);
}

#[test]
fn a_stopped_stream_accepts_writes_and_still_delivers_the_partners_bytes() {
	let mut pair = pair();
	let id = conn_id(pair.conn);
	let mut records = Records::new();
	fill_outbound_until_refused(pair.conn);
	records.drain(&pair.client, id);
	records.forget();

	// The partner stops reading this stream and keeps the connection and its own send stream.
	drop(pair.partner_recv.take());
	wait_for("EV_WRITABLE after the partner stopped the stream", || {
		records.drain(&pair.client, id);
		records.saw(EV_WRITABLE)
	});
	assert_eq!(
		try_write(pair.conn, b"retry"),
		5,
		"the held write was refused after the stop"
	);

	// The partner's later bytes arrive in order while no record has reported the connection closed.
	let mut send = pair.partner_send.take().unwrap();
	pair.server
		.rt
		.block_on(async { send.write_all(&pattern(0..10_000)).await.unwrap() });
	assert_eq!(read_pattern(&pair, &mut records, 0, Some(10_000), || {}), 10_000);
	assert!(!records.saw(EV_CLOSED), "a stop alone reported the connection closed");
	pair.server.rt.block_on(async { send.finish().unwrap() });
	assert_eq!(read_pattern(&pair, &mut records, 10_000, None, || {}), 0);
	release(pair, Vec::new());
}

#[test]
fn a_stop_seen_by_an_idle_writer_follows_the_first_write_and_stores_nothing_after() {
	let mut pair = pair();

	// Nothing is queued, so the writer is idle when the partner stops the stream.
	drop(pair.partner_recv.take());
	assert_eq!(try_write(pair.conn, b"first"), 5);
	// The stop may reach the writer after the first write completes: later writes reach it as well.
	wait_for("the writer to observe the stop", || {
		assert_eq!(try_write(pair.conn, b"x"), 1);
		outbound_state(pair.conn).stopped
	});
	assert_eq!(try_write(pair.conn, &[1u8; 4096]), 4096);
	assert_eq!(
		outbound_state(pair.conn).pending(),
		0,
		"a write after the stop was stored"
	);
	release(pair, Vec::new());
}

#[test]
fn a_partner_that_stops_and_keeps_sending_is_read_in_order_while_writes_store_nothing() {
	const BYTES: usize = 3 << 20;
	let mut pair = pair();
	let id = conn_id(pair.conn);
	let mut records = Records::new();
	fill_outbound_until_refused(pair.conn);
	let OutboundState {
		in_flight,
		queued,
		capacity,
		..
	} = outbound_state(pair.conn);
	assert!(
		in_flight > 0 && queued > NB_STEADY_BYTES && capacity > NB_STEADY_BYTES,
		"the writer was not held behind a queue: {in_flight} in flight, {queued} queued in {capacity}"
	);
	drop(pair.partner_recv.take());
	wait_for("the writer to observe the stop", || {
		// A refused write is retried until the stop releases the queue.
		let _ = try_write(pair.conn, b"x");
		outbound_state(pair.conn).stopped
	});
	let (_streamer_accepted, streamer) = stream_pattern(&mut pair, BYTES, true);
	let total = read_pattern(&pair, &mut records, 0, None, || {
		assert_eq!(try_write(pair.conn, &[1u8; 4096]), 4096);
		let state = outbound_state(pair.conn);
		let (capacity, pending) = (state.capacity, state.pending());
		assert_eq!(pending, 0, "a write after the stop was stored");
		assert!(
			capacity <= NB_STEADY_BYTES,
			"the outbound storage kept {capacity} bytes"
		);
	});
	assert_eq!(total, BYTES);
	wait_for("EV_READABLE | EV_CLOSED", || {
		records.drain(&pair.client, id);
		records.saw(EV_READABLE | EV_CLOSED)
	});
	release(pair, vec![streamer]);
}
