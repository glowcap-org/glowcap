//! Terminal channel state: a close or failure is published once, and the first
//! cause decides the open and read results.

use super::*;

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
	let events = drain_records(&readiness, 1);
	assert_eq!(events.len(), 1);
	assert_eq!(events[0].subject, 7);
	assert_eq!(events[0].events, EV_CLOSED);

	publish_peer_closed(&shared);
	assert!(drain_records(&readiness, 1).is_empty());
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
fn a_send_on_an_ended_channel_names_its_ending() {
	let open_peer = |id| {
		test_shared(
			id,
			Arc::new((Mutex::new(Inbound { ..empty_inbound() }), Condvar::new())),
			Arc::new(Mutex::new(OpenGate {
				open: true,
				closed: false,
				failed: false,
			})),
			Arc::new(Notify::new()),
			Readiness::new().unwrap(),
		)
	};
	let closed = open_peer(9);
	publish_peer_closed(&closed);
	assert_eq!(try_send(&closed, b"late"), CLOSED as isize);

	let failed = open_peer(10);
	publish_peer_failed(&failed);
	assert_eq!(try_send(&failed, b"late"), ERR as isize);

	let opening = open_peer(11);
	opening.open.lock().unwrap().open = false;
	assert_eq!(try_send(&opening, b"early"), WOULD_BLOCK as isize);
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
