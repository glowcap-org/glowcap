//! Unit tests for the sidecar's parse, buffer, and admission seams.

use super::*;
use std::io::{Read, Write};
use std::net::UdpSocket;
use std::sync::atomic::AtomicBool;
use std::time::{Duration, Instant};

pub(super) fn direct_endpoint(connect_timeout_ms: u64) -> *mut GlowcapIrohEndpoint {
	let config = GlowcapIrohEndpointConfig {
		reachability: REACH_DIRECT,
		connect_timeout_ms,
		idle_timeout_ms: 0,
		worker_threads: 0,
	};
	glowcap_iroh_sidecar_endpoint_new(std::ptr::null(), &config)
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
	let mut outbound = Outbound::default();
	outbound.in_flight = NB_BUFFER_BOUND - 4;

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
	outbound.finish_batch(batch, true);

	let spare_ptr = outbound.spare.as_ptr();
	let second = outbound.take_batch();
	assert_eq!(outbound.buf.as_ptr(), spare_ptr);
	assert_eq!(outbound.pending(), NB_STEADY_BYTES);
	outbound.finish_batch(second, true);
	assert!(outbound.spare.capacity() <= NB_STEADY_BYTES);
}

#[test]
fn blocking_accept_timeout_does_not_arm_or_drain_readiness() {
	let ep = direct_endpoint(200);
	assert!(!ep.is_null(), "endpoint_new");
	let started = Instant::now();
	let mut code = -1;
	let conn = glowcap_iroh_sidecar_accept_timeout(ep, 20, &mut code);
	assert!(conn.is_null());
	assert_eq!(code, DIAL_TIMEOUT);
	assert!(started.elapsed() >= Duration::from_millis(5));
	assert!(started.elapsed() < Duration::from_secs(1));
	let endpoint = unsafe { &*ep };
	assert!(endpoint.readiness.get().is_none());
	assert!(endpoint.accept.get().is_none());
	glowcap_iroh_sidecar_endpoint_free(ep);
}

#[test]
fn blocking_accept_reports_endpoint_close_as_lost_not_timeout() {
	let ep = direct_endpoint(200);
	assert!(!ep.is_null(), "endpoint_new");
	glowcap_iroh_sidecar_endpoint_close(ep);
	let mut code = -1;
	let conn = glowcap_iroh_sidecar_accept_timeout(ep, 1000, &mut code);
	assert!(conn.is_null());
	assert_eq!(code, DIAL_LOST);
	glowcap_iroh_sidecar_endpoint_free(ep);
}

#[test]
fn endpoint_release_joins_writers_detached_by_connection_release() {
	let ep = direct_endpoint(200);
	assert!(!ep.is_null(), "endpoint_new");
	let finished = Arc::new(AtomicBool::new(false));
	let task_finished = finished.clone();
	let endpoint = unsafe { &*ep };
	let permit = endpoint.writers.acquire();
	let writer = endpoint.rt.spawn(async move {
		tokio::time::sleep(Duration::from_millis(20)).await;
		task_finished.store(true, Ordering::Release);
		permit.succeed();
	});
	drop(writer);

	assert_eq!(glowcap_iroh_sidecar_endpoint_free(ep), 0);
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

fn wait_event(ep: *mut GlowcapIrohEndpoint) -> GlowcapIrohReadyEvent {
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

#[test]
fn evented_connect_returns_promptly_and_times_out_once() {
	let (_black_hole, unreachable_id, hint) = black_hole_target();
	// 200ms per-endpoint deadline; direct reachability so the dial uses only
	// our hint (no discovery, no relays), leaving the black hole the sole route.
	let ep = direct_endpoint(200);
	assert!(!ep.is_null(), "endpoint_new");

	let started = Instant::now();
	let code = glowcap_iroh_sidecar_endpoint_start_connect(
		ep,
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

	let event = wait_event(ep);
	assert_eq!(event.subject, 1);
	assert_eq!(event.events, EV_CONNECT);

	let mut conn = std::ptr::null_mut();
	assert_eq!(
		glowcap_iroh_sidecar_endpoint_finish_connect(ep, 1, &mut conn),
		DIAL_TIMEOUT
	);
	assert!(conn.is_null());
	assert_eq!(
		glowcap_iroh_sidecar_endpoint_finish_connect(ep, 1, &mut conn),
		DIAL_INVALID,
		"terminal result is one-shot"
	);
	let mut events = [GlowcapIrohReadyEvent { subject: 0, events: 0 }; 1];
	assert_eq!(
		glowcap_iroh_sidecar_endpoint_drain_ready(ep, events.as_mut_ptr(), events.len()),
		0,
		"one admitted dial emits exactly one terminal event"
	);

	glowcap_iroh_sidecar_endpoint_free(ep);
}

#[test]
fn rejected_connect_owes_no_event() {
	let ep = direct_endpoint(200);
	assert!(!ep.is_null(), "endpoint_new");
	let invalid = b"not-an-endpoint-id";
	assert_eq!(
		glowcap_iroh_sidecar_endpoint_start_connect(ep, 1, invalid.as_ptr(), invalid.len(), std::ptr::null(), 0,),
		DIAL_INVALID
	);
	let mut event = GlowcapIrohReadyEvent { subject: 0, events: 0 };
	assert_eq!(glowcap_iroh_sidecar_endpoint_drain_ready(ep, &mut event, 1), 0);
	glowcap_iroh_sidecar_endpoint_free(ep);
}

#[test]
fn evented_connect_admission_is_bounded_and_reclaimed() {
	let (_black_hole, unreachable_id, hint) = black_hole_target();
	let ep = direct_endpoint(5_000);
	assert!(!ep.is_null(), "endpoint_new");

	for request_id in 1..=DIAL_ADMISSION_BOUND {
		assert_eq!(
			glowcap_iroh_sidecar_endpoint_start_connect(
				ep,
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
			ep,
			DIAL_ADMISSION_BOUND + 1,
			unreachable_id.as_ptr(),
			unreachable_id.len(),
			hint.as_ptr(),
			hint.len(),
		),
		DIAL_BUSY
	);

	for request_id in 1..=DIAL_ADMISSION_BOUND {
		assert_eq!(glowcap_iroh_sidecar_endpoint_cancel_connect(ep, request_id), DIAL_OK);
		let mut conn = std::ptr::null_mut();
		assert_eq!(
			glowcap_iroh_sidecar_endpoint_finish_connect(ep, request_id, &mut conn),
			DIAL_CANCELED
		);
	}

	let replacement_id = DIAL_ADMISSION_BOUND + 2;
	assert_eq!(
		glowcap_iroh_sidecar_endpoint_start_connect(
			ep,
			replacement_id,
			unreachable_id.as_ptr(),
			unreachable_id.len(),
			hint.as_ptr(),
			hint.len(),
		),
		DIAL_OK
	);
	assert_eq!(
		glowcap_iroh_sidecar_endpoint_cancel_connect(ep, replacement_id),
		DIAL_OK
	);
	let mut conn = std::ptr::null_mut();
	assert_eq!(
		glowcap_iroh_sidecar_endpoint_finish_connect(ep, replacement_id, &mut conn),
		DIAL_CANCELED
	);
	glowcap_iroh_sidecar_endpoint_free(ep);
}

#[test]
fn canceled_connect_finishes_once() {
	let (_black_hole, unreachable_id, hint) = black_hole_target();
	let ep = direct_endpoint(5_000);
	assert!(!ep.is_null(), "endpoint_new");
	assert_eq!(
		glowcap_iroh_sidecar_endpoint_start_connect(
			ep,
			23,
			unreachable_id.as_ptr(),
			unreachable_id.len(),
			hint.as_ptr(),
			hint.len(),
		),
		DIAL_OK
	);
	assert_eq!(glowcap_iroh_sidecar_endpoint_cancel_connect(ep, 23), DIAL_OK);
	assert_eq!(
		glowcap_iroh_sidecar_endpoint_cancel_connect(ep, 23),
		DIAL_OK,
		"cancel is idempotent while the terminal row exists"
	);

	let event = wait_event(ep);
	assert_eq!(event.subject, 23);
	assert_eq!(event.events, EV_CONNECT);
	let mut conn = std::ptr::null_mut();
	assert_eq!(
		glowcap_iroh_sidecar_endpoint_finish_connect(ep, 23, &mut conn),
		DIAL_CANCELED
	);
	assert!(conn.is_null());
	assert_eq!(
		glowcap_iroh_sidecar_endpoint_finish_connect(ep, 23, &mut conn),
		DIAL_INVALID
	);
	glowcap_iroh_sidecar_endpoint_free(ep);
}
