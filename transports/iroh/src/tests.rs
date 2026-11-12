//! Unit tests for the sidecar's parse, buffer, and admission seams.

use super::*;
use std::io::{Read, Write};
use std::net::UdpSocket;
use std::sync::atomic::AtomicBool;
use std::time::{Duration, Instant};

// These wrappers exercise the C surface with buffers owned by each test and an
// endpoint the test holds as an owned `Box`. A wrapper takes the endpoint by
// reference, so the handle it passes is live for the call by construction, and
// `handle` is the one place a test endpoint becomes a C handle. Keeping the
// unsafe calls here makes that repeated test contract explicit without hiding
// unsafe operations in production helpers.

/// The C handle for an endpoint a test borrows. Every entry point the tests
/// reach borrows its endpoint shared, so a pointer from a shared reference is
/// the handle it expects.
pub(super) fn handle(ep: &GlowcapIrohEndpoint) -> *mut GlowcapIrohEndpoint {
	std::ptr::from_ref(ep).cast_mut()
}

fn glowcap_iroh_sidecar_accept_timeout(
	ep: &GlowcapIrohEndpoint,
	timeout_ms: i32,
	out_code: *mut i32,
) -> *mut GlowcapIrohConn {
	// SAFETY: `ep` is borrowed for the call, and the callers pass `out_code` as `&mut` to a local `i32` that outlives
	// it.
	unsafe { crate::connect::glowcap_iroh_sidecar_accept_timeout(handle(ep), timeout_ms, out_code) }
}

fn glowcap_iroh_sidecar_endpoint_drain_ready(
	ep: &GlowcapIrohEndpoint,
	out: *mut GlowcapIrohReadyEvent,
	out_cap: usize,
) -> isize {
	// SAFETY: `ep` is borrowed for the call, and the callers pass an `out` that addresses `out_cap` events in a local
	// array or `&mut` event outliving it. The callee writes at most `out_cap` events.
	unsafe { crate::nonblocking::calls::glowcap_iroh_sidecar_endpoint_drain_ready(handle(ep), out, out_cap) }
}

fn glowcap_iroh_sidecar_endpoint_start_connect(
	ep: &GlowcapIrohEndpoint,
	request_id: usize,
	node_id: *const u8,
	node_id_len: usize,
	addr_hints: *const u8,
	addr_hints_len: usize,
) -> i32 {
	// SAFETY: `ep` is borrowed for the call, and the callers pass target bytes from local `String` or `str` values that
	// outlive it. The callee parses them into an owned address before returning.
	unsafe {
		crate::connect::glowcap_iroh_sidecar_endpoint_start_connect(
			handle(ep),
			request_id,
			node_id,
			node_id_len,
			addr_hints,
			addr_hints_len,
		)
	}
}

fn glowcap_iroh_sidecar_endpoint_finish_connect(
	ep: &GlowcapIrohEndpoint,
	request_id: usize,
	out_conn: *mut *mut GlowcapIrohConn,
	out_text: *mut u8,
	out_text_cap: usize,
	out_text_len: *mut usize,
) -> i32 {
	// SAFETY: `ep` is borrowed for the call, and the callers pass `out_conn` and `out_text_len` as `&mut` to locals and
	// `out_text` with its true capacity from a local buffer. The callee writes only within those bounds.
	unsafe {
		crate::connect::glowcap_iroh_sidecar_endpoint_finish_connect(
			handle(ep),
			request_id,
			out_conn,
			out_text,
			out_text_cap,
			out_text_len,
		)
	}
}

fn glowcap_iroh_sidecar_endpoint_cancel_connect(ep: &GlowcapIrohEndpoint, request_id: usize) -> i32 {
	// SAFETY: `ep` is borrowed for the call, and the callee only reads a request id from the dial table.
	unsafe { crate::connect::glowcap_iroh_sidecar_endpoint_cancel_connect(handle(ep), request_id) }
}

pub(super) fn direct_endpoint(connect_timeout_ms: u64) -> Box<GlowcapIrohEndpoint> {
	let config = GlowcapIrohEndpointConfig {
		reachability: REACH_DIRECT,
		connect_timeout_ms,
		idle_timeout_ms: 0,
		worker_threads: 0,
	};
	GlowcapIrohEndpoint::bind(None, config).expect("a direct endpoint binds")
}

/// Release an endpoint through the C entry point, the subject of every caller
/// that asserts its status.
pub(super) fn free_endpoint(endpoint: Box<GlowcapIrohEndpoint>) -> i32 {
	// SAFETY: the box is the test's owned endpoint, and tests call this after releasing every connection they minted.
	unsafe { glowcap_iroh_sidecar_endpoint_free(Box::into_raw(endpoint)) }
}

fn close_endpoint(endpoint: &GlowcapIrohEndpoint) {
	// SAFETY: `endpoint` is borrowed for the call, and closing leaves it valid.
	unsafe { glowcap_iroh_sidecar_endpoint_close(handle(endpoint)) }
}

#[test]
fn null_nonblocking_handles_are_refused_without_dereference() {
	// SAFETY: every pointer here is null and every length zero; each function under test checks its endpoint or
	// connection handle for null and returns before it dereferences a handle or touches `out` or `buf`.
	unsafe {
		assert_eq!(
			crate::nonblocking::calls::glowcap_iroh_sidecar_endpoint_readiness_fd(std::ptr::null()),
			-1
		);
		assert_eq!(
			crate::nonblocking::calls::glowcap_iroh_sidecar_endpoint_drain_ready(
				std::ptr::null(),
				std::ptr::null_mut(),
				0
			),
			-1
		);
		assert_eq!(
			crate::nonblocking::calls::glowcap_iroh_sidecar_endpoint_set_nonblocking_accept(std::ptr::null_mut()),
			-1
		);
		assert!(crate::nonblocking::calls::glowcap_iroh_sidecar_endpoint_try_accept(std::ptr::null_mut()).is_null());
		assert_eq!(
			crate::nonblocking::calls::glowcap_iroh_sidecar_conn_id(std::ptr::null()),
			0
		);
		assert_eq!(
			crate::nonblocking::calls::glowcap_iroh_sidecar_conn_try_read(
				std::ptr::null_mut(),
				std::ptr::null_mut(),
				0
			),
			-1
		);
		assert_eq!(
			crate::nonblocking::calls::glowcap_iroh_sidecar_conn_try_write(std::ptr::null_mut(), std::ptr::null(), 0),
			-1
		);
	}
}

/// A null endpoint handle is refused with each entry point's documented error
/// value and never reaches a dereference. The identity and address queries are
/// the two that once dereferenced it.
#[test]
fn null_endpoint_handles_are_refused_without_dereference() {
	let mut out = [0u8; 128];
	let mut code = -1;
	let mut conn = std::ptr::null_mut();
	let id = b"id";
	// SAFETY: every endpoint handle here is null, and each function under test refuses it before touching a handle.
	// The other pointers are locals that outlive the calls.
	unsafe {
		assert_eq!(
			glowcap_iroh_sidecar_endpoint_node_id(std::ptr::null(), out.as_mut_ptr(), out.len()),
			-1
		);
		assert_eq!(
			glowcap_iroh_sidecar_endpoint_direct_addrs(std::ptr::null(), out.as_mut_ptr(), out.len()),
			-1
		);
		glowcap_iroh_sidecar_endpoint_close(std::ptr::null_mut());
		assert!(glowcap_iroh_sidecar_endpoint_new(std::ptr::null(), std::ptr::null()).is_null());
		assert!(
			crate::connect::glowcap_iroh_sidecar_connect_blocking(
				std::ptr::null_mut(),
				id.as_ptr(),
				id.len(),
				std::ptr::null(),
				0,
				&mut code,
				std::ptr::null_mut(),
				0,
				std::ptr::null_mut(),
			)
			.is_null()
		);
		assert_eq!(code, DIAL_INVALID);
		code = -1;
		assert!(crate::connect::glowcap_iroh_sidecar_accept_timeout(std::ptr::null_mut(), 0, &mut code).is_null());
		assert_eq!(code, DIAL_INVALID);
		assert_eq!(
			crate::connect::glowcap_iroh_sidecar_endpoint_start_connect(
				std::ptr::null_mut(),
				1,
				id.as_ptr(),
				id.len(),
				std::ptr::null(),
				0
			),
			DIAL_INVALID
		);
		assert_eq!(
			crate::connect::glowcap_iroh_sidecar_endpoint_finish_connect(
				std::ptr::null_mut(),
				1,
				&mut conn,
				std::ptr::null_mut(),
				0,
				std::ptr::null_mut()
			),
			DIAL_INVALID
		);
		assert_eq!(
			crate::connect::glowcap_iroh_sidecar_endpoint_cancel_connect(std::ptr::null_mut(), 1),
			DIAL_INVALID
		);
		assert_eq!(
			crate::nonblocking::calls::glowcap_iroh_sidecar_endpoint_admission(std::ptr::null_mut(), 1),
			-1
		);
	}
	assert!(conn.is_null());
}

/// A caller's seed is the endpoint's key: the id the C constructor's endpoint
/// reports is that key's public half.
#[test]
fn a_seeded_endpoint_reports_its_own_id() {
	let seed = [9u8; 32];
	let config = GlowcapIrohEndpointConfig {
		reachability: REACH_DIRECT,
		connect_timeout_ms: 0,
		idle_timeout_ms: 0,
		worker_threads: 1,
	};
	// SAFETY: `seed` and `config` are locals that outlive the call.
	let ep = unsafe { glowcap_iroh_sidecar_endpoint_new(seed.as_ptr(), &config) };
	let mut out = [0u8; 128];
	// SAFETY: `ep` is null or the endpoint just created, and `out` is a local buffer of the capacity passed.
	let len = unsafe { glowcap_iroh_sidecar_endpoint_node_id(ep, out.as_mut_ptr(), out.len()) };
	let expected = SecretKey::from(seed).public().to_string();
	assert_eq!(&out[..usize::try_from(len).unwrap()], expected.as_bytes());
	// SAFETY: `ep` is the endpoint created above, released once here.
	assert_eq!(unsafe { glowcap_iroh_sidecar_endpoint_free(ep) }, 0);
}

#[test]
fn a_full_self_pipe_is_already_a_readable_wakeup() {
	let readiness = Readiness::new().unwrap();
	readiness.fill_wake_pipe();

	readiness.signal(7, EV_READABLE);
	let mut byte = [0u8; 1];
	let mut reader = &readiness.reader;
	assert_eq!(reader.read(&mut byte).unwrap(), 1);
	assert_eq!(readiness.pending_len(), 1);
}

#[test]
fn drain_owns_wake_bytes_and_the_exported_half_is_read_only() {
	let readiness = Readiness::new().unwrap();
	let mut exported = &readiness.reader;
	assert!(exported.write_all(&[1]).is_err());

	readiness.signal(7, EV_WRITABLE);
	let mut events = [GlowcapIrohReadyEvent { subject: 0, events: 0 }];
	assert_eq!(readiness.drain(&mut events), 1);
	assert_eq!(events[0].subject, 7);
	assert_eq!(events[0].events, EV_WRITABLE);

	let mut byte = [0u8; 1];
	let err = exported.read(&mut byte).unwrap_err();
	assert_eq!(err.kind(), std::io::ErrorKind::WouldBlock);
}

#[test]
fn readiness_queue_coalesces_without_losing_distinct_subjects() {
	let readiness = Readiness::new().unwrap();
	const SUBJECTS: usize = 20_000;
	for subject in 1..=SUBJECTS {
		readiness.signal(subject, EV_READABLE);
	}
	assert_eq!(readiness.pending_len(), SUBJECTS);

	readiness.signal(7, EV_WRITABLE);
	assert_eq!(readiness.pending_len(), SUBJECTS);

	let mut events = vec![GlowcapIrohReadyEvent { subject: 0, events: 0 }; SUBJECTS];
	assert_eq!(readiness.drain(&mut events), SUBJECTS);
	assert_eq!(events[6].subject, 7);
	assert_eq!(events[6].events, EV_READABLE | EV_WRITABLE);
	assert_eq!(events.last().unwrap().subject, SUBJECTS);
}

#[test]
fn outbound_bound_admits_a_prefix_and_blocks_only_when_full() {
	let mut outbound = Outbound {
		in_flight: NB_BUFFER_BOUND - 4,
		..Outbound::default()
	};

	let bytes = [9u8; 16];
	assert_eq!(enqueue_outbound(&mut outbound, &bytes), 4);
	assert_eq!(outbound.pending(), NB_BUFFER_BOUND);
	assert_eq!(enqueue_outbound(&mut outbound, &bytes), WOULD_BLOCK);
}

#[test]
fn inbound_read_budget_never_exceeds_remaining_capacity() {
	let mut inbound = Inbound::default();
	assert_eq!(inbound.read_budget(), READ_CHUNK_BYTES);

	inbound.buf.resize(NB_BUFFER_BOUND - 7, 0);
	assert_eq!(inbound.read_budget(), 7);

	inbound.buf.resize(NB_BUFFER_BOUND, 0);
	assert_eq!(inbound.read_budget(), 0);
}

#[test]
fn outbound_reuses_one_steady_spare_without_double_spending_the_bound() {
	let mut outbound = Outbound::default();
	let bytes = vec![9u8; NB_STEADY_BYTES];
	assert_eq!(enqueue_outbound(&mut outbound, &bytes), NB_STEADY_BYTES as isize);

	let batch = outbound.take_batch();
	assert_eq!(outbound.pending(), NB_STEADY_BYTES);
	assert_eq!(enqueue_outbound(&mut outbound, &bytes), NB_STEADY_BYTES as isize);
	assert!(!outbound.finish_batch(batch, true));

	let spare_ptr = outbound.spare.as_ptr();
	let second = outbound.take_batch();
	assert_eq!(outbound.buf.as_ptr(), spare_ptr);
	assert_eq!(outbound.pending(), NB_STEADY_BYTES);
	assert!(!outbound.finish_batch(second, true));
	assert!(outbound.spare.capacity() <= NB_STEADY_BYTES);
}

#[test]
fn batch_failure_observes_an_application_close_while_the_write_was_in_flight() {
	let mut outbound = Outbound::default();
	assert_eq!(enqueue_outbound(&mut outbound, b"farewell"), 8);
	let batch = outbound.take_batch();

	// The writer released this lock before awaiting QUIC. Model conn_close
	// acquiring it during that await, then the write completing unsuccessfully.
	outbound.closed = true;
	assert!(outbound.finish_batch(batch, false));

	let mut open = Outbound::default();
	assert_eq!(enqueue_outbound(&mut open, b"live write"), 10);
	let batch = open.take_batch();
	assert!(!open.finish_batch(batch, false));
	assert!(open.closed, "a transport failure still closes further admission");
}

#[test]
fn blocking_accept_timeout_does_not_arm_or_drain_readiness() {
	let ep = direct_endpoint(200);
	let started = Instant::now();
	let mut code = -1;
	let conn = glowcap_iroh_sidecar_accept_timeout(&ep, 20, &mut code);
	assert!(conn.is_null());
	assert_eq!(code, DIAL_TIMEOUT);
	assert!(started.elapsed() >= Duration::from_millis(5));
	assert!(started.elapsed() < Duration::from_secs(1));
	assert!(ep.readiness.get().is_none());
	assert!(ep.accept.get().is_none());
	free_endpoint(ep);
}

#[test]
fn blocking_accept_reports_endpoint_close_as_lost_not_timeout() {
	let ep = direct_endpoint(200);
	close_endpoint(&ep);
	let mut code = -1;
	let conn = glowcap_iroh_sidecar_accept_timeout(&ep, 1000, &mut code);
	assert!(conn.is_null());
	assert_eq!(code, DIAL_LOST);
	free_endpoint(ep);
}

#[test]
fn endpoint_release_joins_writers_detached_by_connection_release() {
	let ep = direct_endpoint(200);
	let finished = Arc::new(AtomicBool::new(false));
	let task_finished = finished.clone();
	let permit = ep.writers.acquire();
	let writer = ep.rt.spawn(async move {
		tokio::time::sleep(Duration::from_millis(20)).await;
		task_finished.store(true, Ordering::Release);
		permit.succeed();
	});
	drop(writer);

	assert_eq!(free_endpoint(ep), 0);
	assert!(
		finished.load(Ordering::Acquire),
		"runtime shutdown abandoned a writer whose connection transferred ownership"
	);
}

fn black_hole_target() -> (UdpSocket, String, String) {
	// Keeping the port bound prevents an ICMP port-unreachable from turning
	// the intended pending dial into an immediate failure.
	let socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).expect("bind black hole");
	let hint = socket.local_addr().expect("black hole addr").to_string();
	let endpoint_id = SecretKey::from([7u8; 32]).public().to_string();
	(socket, endpoint_id, hint)
}

fn wait_event(ep: &GlowcapIrohEndpoint) -> GlowcapIrohReadyEvent {
	let deadline = Instant::now() + Duration::from_secs(5);
	let mut events = [GlowcapIrohReadyEvent { subject: 0, events: 0 }; 4];
	loop {
		let n = glowcap_iroh_sidecar_endpoint_drain_ready(ep, events.as_mut_ptr(), events.len());
		if n > 0 {
			return events[0];
		}
		assert!(Instant::now() < deadline, "timed out waiting for readiness");
		std::thread::sleep(Duration::from_millis(10));
	}
}

/// A short caller-set connect timeout must trip fast. The dial's only route is
/// a bound-but-silent UDP black hole: because the port is bound, the OS never
/// answers the QUIC handshake and never sends an ICMP port-unreachable that
/// would fail the dial fast, so the connect can end only by the deadline. A
/// 200ms endpoint therefore publishes a timeout in well under the 30s default,
/// proving the per-endpoint `connect_timeout` reaches the connect await rather
/// than merely that some dial eventually fails. Hermetic: `REACH_DIRECT` binds
/// relay-less and lookup-less, and every address is loopback.
#[test]
fn inner_connect_timeout_keeps_its_timeout_classification() {
	assert_eq!(connection_failure_code(&ConnectionError::TimedOut), DIAL_TIMEOUT);
	assert_eq!(connection_failure_code(&ConnectionError::Reset), DIAL_UNREACHABLE);
}

/// The retained text is bounded at `DIAL_TEXT_BYTES` and never splits a UTF-8
/// sequence, on the way in and on the way out to a shorter caller buffer.
#[test]
fn dial_text_truncates_at_a_char_boundary() {
	// A three-byte character never divides the bound evenly, so the cut lands
	// inside one and the whole character has to go.
	let long = "€".repeat(DIAL_TEXT_BYTES);
	let text = DialText::describe(format_args!("{long}"));
	assert_eq!(text.as_str().len(), DIAL_TEXT_BYTES - DIAL_TEXT_BYTES % 3);
	assert!(text.as_str().chars().all(|c| c == '€'));

	let mut out = [0u8; 4];
	let mut len = usize::MAX;
	text.copy_to(out.as_mut_ptr(), out.len(), &mut len);
	assert_eq!(len, 3, "a copy stops at the last whole character that fits");
	assert_eq!(&out[..3], "€".as_bytes());

	text.copy_to(std::ptr::null_mut(), 0, &mut len);
	assert_eq!(len, 0, "a null buffer declines the text");
}

#[test]
fn evented_connect_returns_promptly_and_times_out_once() {
	let (_black_hole, unreachable_id, hint) = black_hole_target();
	// 200ms per-endpoint deadline; direct reachability so the dial uses only
	// our hint (no discovery, no relays), leaving the black hole the sole route.
	let ep = direct_endpoint(200);

	let started = Instant::now();
	let code = glowcap_iroh_sidecar_endpoint_start_connect(
		&ep,
		1,
		unreachable_id.as_ptr(),
		unreachable_id.len(),
		hint.as_ptr(),
		hint.len(),
	);
	assert_eq!(code, DIAL_OK);
	assert!(
		started.elapsed() < Duration::from_millis(100),
		"start_connect must return promptly"
	);

	let event = wait_event(&ep);
	assert_eq!(event.subject, 1);
	assert_eq!(event.events, EV_CONNECT);

	let mut conn = std::ptr::null_mut();
	let mut text = [0u8; DIAL_TEXT_BYTES];
	let mut text_len = usize::MAX;
	assert_eq!(
		glowcap_iroh_sidecar_endpoint_finish_connect(&ep, 1, &mut conn, text.as_mut_ptr(), text.len(), &mut text_len),
		DIAL_TIMEOUT
	);
	assert!(conn.is_null());
	let message = std::str::from_utf8(&text[..text_len]).expect("dial text is whole UTF-8");
	assert!(
		message.contains("200 ms"),
		"a timed-out dial names the deadline it missed: {message:?}"
	);
	assert_eq!(
		glowcap_iroh_sidecar_endpoint_finish_connect(&ep, 1, &mut conn, text.as_mut_ptr(), text.len(), &mut text_len),
		DIAL_INVALID,
		"terminal result is one-shot"
	);
	assert_eq!(text_len, 0, "a consumed row leaves no text behind");
	let mut events = [GlowcapIrohReadyEvent { subject: 0, events: 0 }; 1];
	assert_eq!(
		glowcap_iroh_sidecar_endpoint_drain_ready(&ep, events.as_mut_ptr(), events.len()),
		0,
		"one admitted dial emits exactly one terminal event"
	);

	free_endpoint(ep);
}

#[test]
fn rejected_connect_owes_no_event() {
	let ep = direct_endpoint(200);
	let invalid = b"not-an-endpoint-id";
	assert_eq!(
		glowcap_iroh_sidecar_endpoint_start_connect(&ep, 1, invalid.as_ptr(), invalid.len(), std::ptr::null(), 0,),
		DIAL_INVALID
	);
	let mut event = GlowcapIrohReadyEvent { subject: 0, events: 0 };
	assert_eq!(glowcap_iroh_sidecar_endpoint_drain_ready(&ep, &mut event, 1), 0);
	free_endpoint(ep);
}

#[test]
fn evented_connect_admission_is_bounded_and_reclaimed() {
	let (_black_hole, unreachable_id, hint) = black_hole_target();
	let ep = direct_endpoint(5_000);

	for request_id in 1..=DIAL_ADMISSION_BOUND {
		assert_eq!(
			glowcap_iroh_sidecar_endpoint_start_connect(
				&ep,
				request_id,
				unreachable_id.as_ptr(),
				unreachable_id.len(),
				hint.as_ptr(),
				hint.len(),
			),
			DIAL_OK
		);
	}
	assert_eq!(
		glowcap_iroh_sidecar_endpoint_start_connect(
			&ep,
			DIAL_ADMISSION_BOUND + 1,
			unreachable_id.as_ptr(),
			unreachable_id.len(),
			hint.as_ptr(),
			hint.len(),
		),
		DIAL_BUSY
	);

	for request_id in 1..=DIAL_ADMISSION_BOUND {
		assert_eq!(glowcap_iroh_sidecar_endpoint_cancel_connect(&ep, request_id), DIAL_OK);
		let mut conn = std::ptr::null_mut();
		assert_eq!(
			glowcap_iroh_sidecar_endpoint_finish_connect(
				&ep,
				request_id,
				&mut conn,
				std::ptr::null_mut(),
				0,
				std::ptr::null_mut()
			),
			DIAL_CANCELED
		);
	}

	let replacement_id = DIAL_ADMISSION_BOUND + 2;
	assert_eq!(
		glowcap_iroh_sidecar_endpoint_start_connect(
			&ep,
			replacement_id,
			unreachable_id.as_ptr(),
			unreachable_id.len(),
			hint.as_ptr(),
			hint.len(),
		),
		DIAL_OK
	);
	assert_eq!(
		glowcap_iroh_sidecar_endpoint_cancel_connect(&ep, replacement_id),
		DIAL_OK
	);
	let mut conn = std::ptr::null_mut();
	assert_eq!(
		glowcap_iroh_sidecar_endpoint_finish_connect(
			&ep,
			replacement_id,
			&mut conn,
			std::ptr::null_mut(),
			0,
			std::ptr::null_mut()
		),
		DIAL_CANCELED
	);
	free_endpoint(ep);
}

#[test]
fn canceled_connect_finishes_once() {
	let (_black_hole, unreachable_id, hint) = black_hole_target();
	let ep = direct_endpoint(5_000);
	assert_eq!(
		glowcap_iroh_sidecar_endpoint_start_connect(
			&ep,
			23,
			unreachable_id.as_ptr(),
			unreachable_id.len(),
			hint.as_ptr(),
			hint.len(),
		),
		DIAL_OK
	);
	assert_eq!(glowcap_iroh_sidecar_endpoint_cancel_connect(&ep, 23), DIAL_OK);
	assert_eq!(
		glowcap_iroh_sidecar_endpoint_cancel_connect(&ep, 23),
		DIAL_OK,
		"cancel is idempotent while the terminal row exists"
	);

	let event = wait_event(&ep);
	assert_eq!(event.subject, 23);
	assert_eq!(event.events, EV_CONNECT);
	let mut conn = std::ptr::null_mut();
	let mut text = [0u8; DIAL_TEXT_BYTES];
	let mut text_len = usize::MAX;
	assert_eq!(
		glowcap_iroh_sidecar_endpoint_finish_connect(&ep, 23, &mut conn, text.as_mut_ptr(), text.len(), &mut text_len),
		DIAL_CANCELED
	);
	assert!(conn.is_null());
	assert_eq!(text_len, 0, "a canceled dial's code is the whole fact");
	assert_eq!(
		glowcap_iroh_sidecar_endpoint_finish_connect(&ep, 23, &mut conn, std::ptr::null_mut(), 0, std::ptr::null_mut()),
		DIAL_INVALID
	);
	free_endpoint(ep);
}
