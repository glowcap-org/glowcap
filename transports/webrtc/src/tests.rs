//! Unit tests for the sidecar's buffer, admission, and close seams.

use super::*;

use crate::conn::*;
use crate::signaling::*;
use std::io::{Read, Write};
use std::time::Duration;

mod ice_config;

fn test_endpoint_new(config: *const GlowcapWebrtcEndpointConfig) -> *mut GlowcapWebrtcEndpoint {
	// SAFETY: tests pass null or a live local configuration; malformed nested
	// views are intentional inputs that the constructor validates before use.
	unsafe { glowcap_webrtc_sidecar_endpoint_new(config) }
}

fn full_inbound() -> Arc<(Mutex<Inbound>, Condvar)> {
	Arc::new((
		Mutex::new(Inbound {
			packets: VecDeque::new(),
			queued_bytes: INBOUND_BUFFER_BOUND,
			closed: false,
			failed: false,
		}),
		Condvar::new(),
	))
}

fn empty_inbound() -> Inbound {
	Inbound {
		packets: VecDeque::new(),
		queued_bytes: 0,
		closed: false,
		failed: false,
	}
}

fn assert_no_signal_text(ptr: *const u8, len: usize) {
	// SAFETY: `signal_text` refuses a null pointer or an oversized length before it borrows anything; for any other
	// pair this helper's callers pass the pointer and length of a local array or `Vec` that is live for the call.
	assert!(unsafe { signal_text(ptr, len) }.is_none());
}

fn test_shared(
	id: usize,
	inbound: Arc<(Mutex<Inbound>, Condvar)>,
	open: Arc<Mutex<OpenGate>>,
	drained: Arc<Notify>,
	readiness: Arc<Readiness>,
) -> Arc<PeerShared> {
	let rt = tokio::runtime::Builder::new_multi_thread()
		.worker_threads(1)
		.enable_all()
		.build()
		.unwrap();
	Arc::new(PeerShared {
		endpoint: Arc::new(EndpointInner {
			rt: RuntimeOwner::new(rt),
			close_tasks: Arc::new(TaskBarrier::new()),
			readiness,
			driver_readiness: Mutex::new(None),
			next_peer_id: AtomicUsize::new(id + 1),
			ice_servers: Vec::new(),
			include_loopback: true,
		}),
		id,
		close_started: AtomicBool::new(false),
		pc: Mutex::new(None),
		dc: Mutex::new(None),
		inbound,
		drained,
		outbound: Arc::new(Mutex::new(Outbound {
			packets: VecDeque::new(),
			queued_bytes: 0,
			closed: false,
		})),
		outbound_ready: Arc::new(Notify::new()),
		open,
		local_candidates: Arc::new(Mutex::new(CandidateQueue::new())),
		remote_candidates: Mutex::new(RemoteCandidates {
			description_set: false,
			early: CandidateQueue::new(),
		}),
	})
}

#[tokio::test]
async fn a_full_buffer_makes_the_next_message_wait_for_the_reader() {
	// Without this the far peer could send for as long as it liked and the
	// buffer would keep growing, so one partner could exhaust our memory.
	let inbound = full_inbound();
	let drained = Arc::new(Notify::new());

	let waiting = tokio::spawn({
		let inbound = inbound.clone();
		let drained = drained.clone();
		async move { await_inbound_room(&inbound, &drained, 1).await }
	});

	// Still parked: nothing has read yet.
	tokio::time::sleep(Duration::from_millis(50)).await;
	assert!(!waiting.is_finished());

	// A receive frees space, exactly as `conn_try_receive_packet` does.
	inbound.0.lock().unwrap().queued_bytes -= 1024;
	drained.notify_one();
	assert!(waiting.await.unwrap());
}

#[tokio::test]
async fn a_message_waits_until_the_whole_message_fits_under_the_inbound_bound() {
	let inbound = Arc::new((
		Mutex::new(Inbound {
			packets: VecDeque::new(),
			queued_bytes: INBOUND_BUFFER_BOUND - 8,
			closed: false,
			failed: false,
		}),
		Condvar::new(),
	));
	let drained = Arc::new(Notify::new());

	let waiting = tokio::spawn({
		let inbound = inbound.clone();
		let drained = drained.clone();
		async move { await_inbound_room(&inbound, &drained, 16).await }
	});

	tokio::time::sleep(Duration::from_millis(50)).await;
	assert!(!waiting.is_finished());

	inbound.0.lock().unwrap().queued_bytes -= 8;
	drained.notify_one();
	assert!(waiting.await.unwrap());
}

#[tokio::test]
async fn an_oversized_message_cannot_enter_inbound_staging() {
	let inbound = Arc::new((Mutex::new(Inbound { ..empty_inbound() }), Condvar::new()));
	let drained = Notify::new();

	assert!(!await_inbound_room(&inbound, &drained, INBOUND_BUFFER_BOUND + 1).await);
}

#[tokio::test]
async fn closing_releases_a_message_that_was_waiting_for_room() {
	// Otherwise the handler parks forever on a channel nobody will drain.
	let inbound = full_inbound();
	let drained = Arc::new(Notify::new());

	let waiting = tokio::spawn({
		let inbound = inbound.clone();
		let drained = drained.clone();
		async move { await_inbound_room(&inbound, &drained, 1).await }
	});

	tokio::time::sleep(Duration::from_millis(50)).await;
	assert!(!waiting.is_finished());

	let open = Arc::new(Mutex::new(OpenGate {
		open: false,
		closed: false,
		failed: false,
	}));
	let readiness = Readiness::new().unwrap();
	let shared = test_shared(7, inbound.clone(), open, drained, readiness);
	publish_peer_closed(&shared);
	assert!(!waiting.await.unwrap());
}

#[tokio::test]
async fn a_buffer_with_room_does_not_wait() {
	let inbound = Arc::new((Mutex::new(Inbound { ..empty_inbound() }), Condvar::new()));
	let drained = Notify::new();
	assert!(await_inbound_room(&inbound, &drained, 1).await);
}

#[test]
fn readiness_coalesces_bits_per_stable_peer() {
	let readiness = Readiness::new().unwrap();
	readiness.signal(7, EV_CANDIDATE);
	readiness.signal(7, EV_OPEN | EV_WRITABLE);
	readiness.signal(9, EV_READABLE);

	let mut events = [GlowcapWebrtcReadyEvent { subject: 0, events: 0 }; 2];
	assert_eq!(readiness.drain(&mut events), 2);
	assert_eq!(events[0].subject, 7);
	assert_eq!(events[0].events, EV_CANDIDATE | EV_OPEN | EV_WRITABLE);
	assert_eq!(events[1].subject, 9);
	assert_eq!(events[1].events, EV_READABLE);
}

#[test]
fn signaling_and_driver_readiness_are_independent_subscriptions() {
	let signaling = Readiness::new().unwrap();
	let shared = test_shared(
		7,
		Arc::new((Mutex::new(Inbound { ..empty_inbound() }), Condvar::new())),
		Arc::new(Mutex::new(OpenGate {
			open: false,
			closed: false,
			failed: false,
		})),
		Arc::new(Notify::new()),
		signaling.clone(),
	);
	let driver = shared.endpoint.driver_readiness().unwrap();

	shared.endpoint.signal(7, EV_CANDIDATE | EV_OPEN);
	let mut event = [GlowcapWebrtcReadyEvent { subject: 0, events: 0 }];
	assert_eq!(signaling.drain(&mut event), 1);
	assert_eq!(event[0].events, EV_CANDIDATE | EV_OPEN);
	assert_eq!(driver.drain(&mut event), 1);
	assert_eq!(event[0].events, EV_CANDIDATE | EV_OPEN);
}

#[test]
fn a_full_self_pipe_is_already_a_readable_wakeup() {
	let readiness = Readiness::new().unwrap();
	readiness.fill_wake_pipe();

	// `signal` cannot add another byte, but the full pipe already wakes poll.
	readiness.signal(7, EV_READABLE);
	let mut byte = [0u8; 1];
	let mut reader = &readiness.reader;
	assert_eq!(reader.read(&mut byte).unwrap(), 1);
	let mut event = [GlowcapWebrtcReadyEvent { subject: 0, events: 0 }];
	assert_eq!(readiness.drain(&mut event), 1);
	assert_eq!(event[0].events, EV_READABLE);
}

#[test]
fn the_exported_readiness_half_cannot_be_written() {
	let readiness = Readiness::new().unwrap();
	let mut exported = &readiness.reader;
	assert!(exported.write_all(&[1]).is_err());

	readiness.signal(7, EV_OPEN);
	let mut byte = [0u8; 1];
	let mut exported = &readiness.reader;
	assert_eq!(exported.read(&mut byte).unwrap(), 1);
}

#[test]
fn inbound_packet_read_preserves_boundaries() {
	let mut state = Inbound {
		packets: VecDeque::new(),
		queued_bytes: 3,
		closed: false,
		failed: false,
	};
	state.packets.push_back(BytesMut::from(&b"abc"[..]));
	let mut short = [0u8; 2];
	assert_eq!(take_inbound_packet(&mut state, &mut short), BUFFER_TOO_SMALL as isize);
	assert_eq!(state.queued_bytes, 3);
	assert_eq!(state.packets.len(), 1);

	let mut dest = [0u8; 3];
	assert_eq!(take_inbound_packet(&mut state, &mut dest), 3);
	assert_eq!(&dest, b"abc");
	assert_eq!(state.queued_bytes, 0);
	assert!(state.packets.is_empty());
}

#[test]
fn loopback_binding_is_additive() {
	assert_eq!(peer_connection::udp_bind_addrs(false), vec!["0.0.0.0:0".to_owned()]);
	assert_eq!(
		peer_connection::udp_bind_addrs(true),
		vec!["0.0.0.0:0".to_owned(), "127.0.0.1:0".to_owned()]
	);
}

#[test]
fn outbound_admits_whole_packets_only() {
	let mut state = Outbound {
		packets: VecDeque::new(),
		queued_bytes: 0,
		closed: false,
	};
	let too_large = vec![9u8; MAX_PACKET_BYTES + 1];
	assert_eq!(enqueue_outbound(&mut state, &too_large), BUFFER_TOO_SMALL as isize);

	let packet = vec![7u8; MAX_PACKET_BYTES];
	while state.queued_bytes + packet.len() <= OUTBOUND_BUFFER_BOUND {
		assert_eq!(enqueue_outbound(&mut state, &packet), packet.len() as isize);
	}
	assert_eq!(enqueue_outbound(&mut state, &packet), WOULD_BLOCK as isize);

	let sent = state.packets.pop_front().unwrap();
	state.queued_bytes -= sent.len();
	assert_eq!(enqueue_outbound(&mut state, &packet), packet.len() as isize);
	assert!(state.queued_bytes <= OUTBOUND_BUFFER_BOUND);
}

#[test]
fn local_candidate_queue_bounds_retained_candidate_text() {
	let mut queue = CandidateQueue::new();
	let candidate = "x".repeat(MAX_ICE_CANDIDATE_BYTES);
	while queue.queued_bytes + candidate.len() <= CANDIDATE_QUEUE_BYTES {
		assert!(queue.admit(candidate.clone()));
	}
	assert!(!queue.admit("x".to_string()));

	let mut count_bound = CandidateQueue::new();
	for _ in 0..MAX_PENDING_CANDIDATES {
		assert!(count_bound.admit("x".to_string()));
	}
	assert!(!count_bound.admit("x".to_string()));
	let mut empty = CandidateQueue::new();
	assert!(!empty.admit(String::new()));
	let mut oversized = CandidateQueue::new();
	assert!(!oversized.admit("x".repeat(MAX_ICE_CANDIDATE_BYTES + 1)));
}

#[test]
fn taking_every_held_candidate_frees_the_whole_queue_budget() {
	let mut queue = CandidateQueue::new();
	assert!(queue.admit("first".to_string()));
	assert!(queue.admit("second".to_string()));
	let taken: Vec<String> = queue.take_all().into();
	assert_eq!(taken, ["first", "second"]);
	assert_eq!(queue.queued_bytes, 0);
	assert!(queue.items.is_empty());
	assert!(queue.admit("x".repeat(MAX_ICE_CANDIDATE_BYTES)));
}

#[test]
fn next_local_candidate_retries_without_releasing_the_front() {
	let mut queue = CandidateQueue::new();
	assert!(queue.admit("abcdef".to_string()));
	let mut short = [0u8; 3];
	let mut required: usize = 0;
	// SAFETY: both buffers are this frame's own stack arrays, live throughout.
	let small = unsafe { OutText::new(short.as_mut_ptr(), short.len(), &mut required) };
	assert_eq!(write_local_candidate(&mut queue, &small), BUFFER_TOO_SMALL);
	assert_eq!(required, 6);
	assert_eq!(queue.items.len(), 1);
	assert_eq!(queue.queued_bytes, 6);

	let mut out = [0u8; 6];
	// SAFETY: as the `small` call above, `out` is this frame's own `[u8; 6]` array with `out.len()` its length, and
	// `required` is its own `usize`; all stay live while `roomy` is used.
	let roomy = unsafe { OutText::new(out.as_mut_ptr(), out.len(), &mut required) };
	assert_eq!(write_local_candidate(&mut queue, &roomy), OK);
	assert_eq!(&out, b"abcdef");
	assert_eq!(queue.queued_bytes, 0);
	assert_eq!(write_local_candidate(&mut queue, &roomy), WOULD_BLOCK);
}

#[tokio::test]
async fn runtime_owner_can_drop_inside_an_async_context() {
	let rt = tokio::runtime::Builder::new_multi_thread()
		.worker_threads(1)
		.enable_all()
		.build()
		.unwrap();
	drop(RuntimeOwner::new(rt));
}

#[test]
fn terminal_event_is_published_exactly_once_even_after_a_drain() {
	let inbound = Arc::new((Mutex::new(Inbound { ..empty_inbound() }), Condvar::new()));
	let open = Arc::new(Mutex::new(OpenGate {
		open: false,
		closed: false,
		failed: false,
	}));
	let drained = Arc::new(Notify::new());
	let readiness = Readiness::new().unwrap();
	let shared = test_shared(7, inbound.clone(), open.clone(), drained, readiness.clone());

	publish_peer_closed(&shared);
	let mut events = [GlowcapWebrtcReadyEvent { subject: 0, events: 0 }];
	assert_eq!(readiness.drain(&mut events), 1);
	assert_eq!(events[0].subject, 7);
	assert_eq!(events[0].events, EV_CLOSED);

	publish_peer_closed(&shared);
	assert_eq!(readiness.drain(&mut events), 0);
	assert!(inbound.0.lock().unwrap().closed);
	assert!(open.lock().unwrap().closed);
	assert!(shared.outbound.lock().unwrap().closed);
}

#[test]
fn failed_terminal_state_is_not_reported_as_clean_eof() {
	let inbound = Arc::new((Mutex::new(Inbound { ..empty_inbound() }), Condvar::new()));
	let open = Arc::new(Mutex::new(OpenGate {
		open: true,
		closed: false,
		failed: false,
	}));
	let shared = test_shared(
		7,
		inbound.clone(),
		open,
		Arc::new(Notify::new()),
		Readiness::new().unwrap(),
	);

	publish_peer_failed(&shared);
	let state = inbound.0.lock().unwrap();
	assert!(state.closed);
	assert!(state.failed);
	assert!(state.packets.is_empty());
	drop(state);

	let mut state = empty_inbound();
	state.closed = true;
	assert!(!state.failed);
	assert_eq!(terminal_read_result(&state), 0);

	let mut failed = empty_inbound();
	failed.closed = true;
	failed.failed = true;
	assert_eq!(terminal_read_result(&failed), ERR as isize);
}

#[test]
fn first_terminal_cause_wins_open_and_read_results() {
	let clean_first = test_shared(
		7,
		Arc::new((Mutex::new(Inbound { ..empty_inbound() }), Condvar::new())),
		Arc::new(Mutex::new(OpenGate {
			open: true,
			closed: false,
			failed: false,
		})),
		Arc::new(Notify::new()),
		Readiness::new().unwrap(),
	);
	publish_peer_closed(&clean_first);
	publish_peer_failed(&clean_first);
	{
		let gate = clean_first.open.lock().unwrap();
		assert!(gate.closed);
		assert!(!gate.failed);
	}
	assert_eq!(terminal_read_result(&clean_first.inbound.0.lock().unwrap()), 0);

	let failed_first = test_shared(
		8,
		Arc::new((Mutex::new(Inbound { ..empty_inbound() }), Condvar::new())),
		Arc::new(Mutex::new(OpenGate {
			open: true,
			closed: false,
			failed: false,
		})),
		Arc::new(Notify::new()),
		Readiness::new().unwrap(),
	);
	publish_peer_failed(&failed_first);
	publish_peer_closed(&failed_first);
	{
		let gate = failed_first.open.lock().unwrap();
		assert!(gate.closed);
		assert!(gate.failed);
	}
	assert_eq!(
		terminal_read_result(&failed_first.inbound.0.lock().unwrap()),
		ERR as isize
	);
}

#[test]
fn open_check_distinguishes_clean_close_from_failed_setup() {
	assert_eq!(
		open_result(&OpenGate {
			open: false,
			closed: false,
			failed: false,
		}),
		WOULD_BLOCK
	);
	assert_eq!(
		open_result(&OpenGate {
			open: true,
			closed: false,
			failed: false,
		}),
		OK
	);
	assert_eq!(
		open_result(&OpenGate {
			open: false,
			closed: true,
			failed: false,
		}),
		CLOSED
	);
	assert_eq!(
		open_result(&OpenGate {
			open: false,
			closed: true,
			failed: true,
		}),
		ERR
	);
}

#[test]
fn sidecar_signal_text_bounds_before_borrowing() {
	let valid = b"v=0";
	// SAFETY: `valid` is a local byte-string literal, so `valid.as_ptr()` and `valid.len()` address live readable bytes
	// for the call.
	assert_eq!(unsafe { signal_text(valid.as_ptr(), valid.len()) }, Some("v=0"));
	assert_no_signal_text(std::ptr::null(), valid.len());

	let invalid_utf8 = [0xff];
	assert_no_signal_text(invalid_utf8.as_ptr(), invalid_utf8.len());

	let oversized = vec![b'x'; MAX_SIGNAL_BYTES + 1];
	assert_no_signal_text(oversized.as_ptr(), oversized.len());
}

#[test]
fn sidecar_candidate_text_bounds_before_borrowing() {
	let valid = b"{\"candidate\":\"candidate\"}";
	assert_eq!(
		// SAFETY: `valid` is a local byte-string literal, so `valid.as_ptr()` and `valid.len()` address live readable
		// bytes for the call.
		unsafe { candidate_text(valid.as_ptr(), valid.len()) },
		Some("{\"candidate\":\"candidate\"}")
	);
	// SAFETY: the pointer is null with a nonzero length, which `candidate_text` refuses before it forms a slice.
	assert!(unsafe { candidate_text(std::ptr::null(), valid.len()) }.is_none());

	let invalid_utf8 = [0xff];
	// SAFETY: `invalid_utf8` is a local array, so its pointer and length address live readable bytes for the call;
	// `candidate_text` rejects them as invalid UTF-8.
	assert!(unsafe { candidate_text(invalid_utf8.as_ptr(), invalid_utf8.len()) }.is_none());

	let oversized = vec![b'x'; MAX_ICE_CANDIDATE_BYTES + 1];
	// SAFETY: `oversized` is a local `Vec` of `MAX_ICE_CANDIDATE_BYTES + 1` bytes, live for the call; `candidate_text`
	// refuses the length as over its bound before it forms a slice.
	assert!(unsafe { candidate_text(oversized.as_ptr(), oversized.len()) }.is_none());
}

#[test]
fn generated_signal_text_has_the_same_hard_cap() {
	assert!(signal_output_fits(&"x".repeat(MAX_SIGNAL_BYTES)));
	assert!(!signal_output_fits(&"x".repeat(MAX_SIGNAL_BYTES + 1)));
}

#[test]
fn peer_release_joins_its_close_at_endpoint_release() {
	let config = GlowcapWebrtcEndpointConfig {
		ice_servers: std::ptr::null(),
		ice_server_count: 0,
		include_loopback_candidates: 1,
		worker_threads: 1,
	};
	let endpoint = test_endpoint_new(&config);
	assert!(!endpoint.is_null());
	// SAFETY: `endpoint` is the non-null live handle `test_endpoint_new` returned (asserted above); this test frees it
	// only after releasing the peer it creates here, whose ownership passes to this test.
	let peer = unsafe { glowcap_webrtc_sidecar_peer_new(endpoint, 1) };
	assert!(!peer.is_null());
	// SAFETY: `peer` is the non-null owned handle `peer_new` returned (asserted above), closed (idempotently) and then
	// freed exactly once here; `endpoint` is the live handle from `test_endpoint_new`, freed after its only peer and
	// not used again.
	unsafe {
		glowcap_webrtc_sidecar_conn_close(peer);
		glowcap_webrtc_sidecar_peer_free(peer);
		assert_eq!(glowcap_webrtc_sidecar_endpoint_free(endpoint), OK);
	}
}

#[test]
fn teardown_panics_become_failures() {
	assert_eq!(teardown_status(|| Ok::<(), ()>(())), OK);
	assert_eq!(
		teardown_status(|| -> Result<(), ()> { panic!("forced teardown panic") }),
		ERR
	);
}
