//! Unit tests for the sidecar's buffer, admission, and close seams.

use super::*;

use crate::conn::*;
use crate::signaling::*;
use std::io::{Read, Write};
use std::time::Duration;

fn full_inbound() -> Arc<(Mutex<Inbound>, Condvar)> {
	Arc::new((
		Mutex::new(Inbound {
			buf: std::iter::repeat(0u8).take(INBOUND_BUFFER_BOUND).collect(),
			closed: false,
		}),
		Condvar::new(),
	))
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
			close_tasks: Arc::new(CloseTasks::new()),
			readiness,
			driver_readiness: Mutex::new(None),
			next_peer_id: AtomicUsize::new(id + 1),
			ice_servers: Vec::new(),
			include_loopback: true,
		}),
		id,
		close_started: AtomicBool::new(false),
		dc: Mutex::new(None),
		inbound,
		drained,
		outbound: Arc::new(Mutex::new(Outbound {
			buf: BytesMut::new(),
			queued_bytes: 0,
			closed: false,
		})),
		outbound_ready: Arc::new(Notify::new()),
		open,
		local_candidates: Arc::new(Mutex::new(VecDeque::new())),
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

	// A read frees space, exactly as `conn_read` does.
	inbound.0.lock().unwrap().buf.drain(..1024);
	drained.notify_one();
	assert!(waiting.await.unwrap());
}

#[tokio::test]
async fn a_message_waits_until_the_whole_message_fits_under_the_inbound_bound() {
	let inbound = Arc::new((
		Mutex::new(Inbound {
			buf: std::iter::repeat(0u8).take(INBOUND_BUFFER_BOUND - 8).collect(),
			closed: false,
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

	inbound.0.lock().unwrap().buf.drain(..8);
	drained.notify_one();
	assert!(waiting.await.unwrap());
}

#[tokio::test]
async fn an_oversized_message_cannot_enter_inbound_staging() {
	let inbound = Arc::new((
		Mutex::new(Inbound {
			buf: VecDeque::new(),
			closed: false,
		}),
		Condvar::new(),
	));
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
	}));
	let readiness = Readiness::new().unwrap();
	let shared = test_shared(7, inbound.clone(), open, drained, readiness);
	publish_peer_closed(&shared);
	assert!(!waiting.await.unwrap());
}

#[tokio::test]
async fn a_buffer_with_room_does_not_wait() {
	let inbound = Arc::new((
		Mutex::new(Inbound {
			buf: VecDeque::new(),
			closed: false,
		}),
		Condvar::new(),
	));
	let drained = Notify::new();
	assert!(await_inbound_room(&inbound, &drained, 1).await);
}

#[test]
fn readiness_coalesces_bits_per_stable_peer() {
	let readiness = Readiness::new().unwrap();
	readiness.signal(7, EV_CANDIDATE);
	readiness.signal(7, EV_OPEN | EV_WRITABLE);
	readiness.signal(9, EV_READABLE);

	let mut events = [PancakeWebrtcReadyEvent { subject: 0, events: 0 }; 2];
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
		Arc::new((
			Mutex::new(Inbound {
				buf: VecDeque::new(),
				closed: false,
			}),
			Condvar::new(),
		)),
		Arc::new(Mutex::new(OpenGate {
			open: false,
			closed: false,
		})),
		Arc::new(Notify::new()),
		signaling.clone(),
	);
	let driver = shared.endpoint.driver_readiness().unwrap();

	shared.endpoint.signal(7, EV_CANDIDATE | EV_OPEN);
	let mut event = [PancakeWebrtcReadyEvent { subject: 0, events: 0 }];
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
	let mut event = [PancakeWebrtcReadyEvent { subject: 0, events: 0 }];
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
fn inbound_drain_releases_burst_capacity() {
	let mut state = Inbound {
		buf: VecDeque::with_capacity(INBOUND_BUFFER_BOUND),
		closed: false,
	};
	state.buf.extend(std::iter::repeat(7u8).take(STEADY_BUFFER_BYTES * 2));
	assert!(state.buf.capacity() > STEADY_BUFFER_BYTES);
	let mut dest = vec![0u8; state.buf.len()];
	assert_eq!(take_inbound(&mut state, &mut dest), dest.len());
	assert!(state.buf.is_empty());
	assert!(state.buf.capacity() <= STEADY_BUFFER_BYTES);
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
fn outbound_bound_admits_a_prefix_and_retry_makes_progress() {
	let mut state = Outbound {
		buf: BytesMut::new(),
		queued_bytes: 0,
		closed: false,
	};
	let bytes = vec![9u8; OUTBOUND_BUFFER_BOUND + 17];
	assert_eq!(enqueue_outbound(&mut state, &bytes), OUTBOUND_BUFFER_BOUND as isize);
	assert_eq!(
		enqueue_outbound(&mut state, &bytes[OUTBOUND_BUFFER_BOUND..]),
		WOULD_BLOCK as isize
	);

	let sent = state.buf.split_to(STEADY_BUFFER_BYTES);
	drop(sent);
	state.queued_bytes -= STEADY_BUFFER_BYTES;
	assert_eq!(enqueue_outbound(&mut state, &bytes[OUTBOUND_BUFFER_BOUND..]), 17);
	assert!(state.queued_bytes <= OUTBOUND_BUFFER_BOUND);
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
	let inbound = Arc::new((
		Mutex::new(Inbound {
			buf: VecDeque::new(),
			closed: false,
		}),
		Condvar::new(),
	));
	let open = Arc::new(Mutex::new(OpenGate {
		open: false,
		closed: false,
	}));
	let drained = Arc::new(Notify::new());
	let readiness = Readiness::new().unwrap();
	let shared = test_shared(7, inbound.clone(), open.clone(), drained, readiness.clone());

	publish_peer_closed(&shared);
	let mut events = [PancakeWebrtcReadyEvent { subject: 0, events: 0 }];
	assert_eq!(readiness.drain(&mut events), 1);
	assert_eq!(events[0].subject, 7);
	assert_eq!(events[0].events, EV_CLOSED);

	publish_peer_closed(&shared);
	assert_eq!(readiness.drain(&mut events), 0);
	assert!(inbound.0.lock().unwrap().closed);
	assert!(open.lock().unwrap().closed);
	assert!(shared.outbound.lock().unwrap().closed);
}

/// The ICE servers a caller names reach the endpoint, and a caller that
/// names none still gets one.
///
/// A live STUN server cannot be reached from a hermetic test, so what this
/// holds is the seam rather than the traversal: the URLs are parsed, split,
/// and carried onto the endpoint every peer is built from. Without it the
/// setting would be a claim nothing exercises.
#[test]
fn ice_servers_reach_the_endpoint() {
	let urls = b"stun:stun.example:3478, stun:other.example:3478";
	let cfg = PancakeWebrtcEndpointConfig {
		ice_servers: urls.as_ptr(),
		ice_servers_len: urls.len(),
		include_loopback_candidates: 0,
		worker_threads: 0,
	};
	let ep = pancake_webrtc_sidecar_endpoint_new(&cfg);
	assert!(!ep.is_null());
	// The comma-separated list splits, and surrounding space is not part of
	// a URL.
	assert_eq!(
		unsafe { &*ep }.inner.ice_servers,
		vec![
			"stun:stun.example:3478".to_string(),
			"stun:other.example:3478".to_string()
		]
	);
	unsafe { pancake_webrtc_sidecar_endpoint_free(ep) };

	let empty = PancakeWebrtcEndpointConfig {
		ice_servers: std::ptr::null(),
		ice_servers_len: 0,
		include_loopback_candidates: 0,
		worker_threads: 0,
	};
	let host_only = pancake_webrtc_sidecar_endpoint_new(&empty);
	assert!(!host_only.is_null());
	assert!(unsafe { &*host_only }.inner.ice_servers.is_empty());
	unsafe { pancake_webrtc_sidecar_endpoint_free(host_only) };
}

/// A null config is refused rather than silently taken as "no ICE servers",
/// so a caller that forgot to pass one finds out here instead of in a
/// deployment where nothing can traverse NAT.
#[test]
fn a_null_config_is_refused() {
	assert!(pancake_webrtc_sidecar_endpoint_new(std::ptr::null()).is_null());
}

#[test]
fn peer_release_joins_its_close_at_endpoint_release() {
	let config = PancakeWebrtcEndpointConfig {
		ice_servers: std::ptr::null(),
		ice_servers_len: 0,
		include_loopback_candidates: 1,
		worker_threads: 1,
	};
	let endpoint = pancake_webrtc_sidecar_endpoint_new(&config);
	assert!(!endpoint.is_null());
	let peer = unsafe { pancake_webrtc_sidecar_peer_new(endpoint, 1) };
	assert!(!peer.is_null());
	unsafe {
		pancake_webrtc_sidecar_conn_close(peer);
		pancake_webrtc_sidecar_peer_free(peer);
		assert_eq!(pancake_webrtc_sidecar_endpoint_free(endpoint), OK);
	}
}

#[test]
fn teardown_panics_become_failures() {
	assert_eq!(teardown_status(|| Ok(())), OK);
	assert_eq!(
		teardown_status(|| -> Result<(), ()> { panic!("forced teardown panic") }),
		ERR
	);
}

#[test]
fn close_task_failure_survives_until_the_endpoint_barrier() {
	let tasks = Arc::new(CloseTasks::new());
	drop(tasks.acquire());
	assert_eq!(tasks.wait(), Err(()));
}

#[test]
fn completed_close_task_leaves_the_endpoint_barrier_green() {
	let tasks = Arc::new(CloseTasks::new());
	tasks.acquire().succeed();
	assert_eq!(tasks.wait(), Ok(()));
}
