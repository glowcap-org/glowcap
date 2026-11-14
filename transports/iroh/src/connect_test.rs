//! Evented-connect scenarios: dial timeout, admission, cancellation, and the
//! bounded text a finished dial reports.

use super::*;
use crate::tests::{
	direct_endpoint, free_endpoint, glowcap_iroh_sidecar_endpoint_cancel_connect,
	glowcap_iroh_sidecar_endpoint_drain_ready, glowcap_iroh_sidecar_endpoint_finish_connect,
	glowcap_iroh_sidecar_endpoint_start_connect,
};
use std::net::UdpSocket;
use std::time::{Duration, Instant};

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

/// A timeout inside the connection is still a dial timeout, and a reset is an
/// unreachable peer.
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

/// A short caller-set connect timeout must trip fast. The dial's only route is
/// a bound-but-silent UDP black hole: because the port is bound, the OS never
/// answers the QUIC handshake and never sends an ICMP port-unreachable that
/// would fail the dial fast, so the connect can end only by the deadline. A
/// 200ms endpoint therefore publishes a timeout in well under the 30s default,
/// proving the per-endpoint `connect_timeout` reaches the connect await rather
/// than merely that some dial eventually fails. Hermetic: `REACH_DIRECT` binds
/// relay-less and lookup-less, and every address is loopback.
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
