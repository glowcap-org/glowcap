//! Native driver-loop lifecycle and provider scenarios.

#[cfg(any(feature = "tcp", feature = "iroh"))]
use super::*;
#[cfg(any(feature = "tcp", feature = "iroh"))]
use crate::driver_event::decode as decode_event;
#[cfg(any(feature = "tcp", feature = "iroh"))]
use crate::sys::driver::PancakeDriverEvent;
#[cfg(feature = "tcp")]
use std::sync::atomic::{AtomicBool, Ordering};
#[cfg(feature = "tcp")]
use std::sync::{mpsc, Arc};

#[test]
fn driver_loop_default_frame_cap_uses_generated_abi_constant() {
	assert_eq!(
		super::DriverLoopOptions::default().frame_cap,
		crate::sys::DEFAULT_FRAME_CAP
	);
}

#[cfg(any(feature = "tcp", feature = "iroh"))]
#[test]
fn unknown_native_event_and_completion_kinds_are_returned_failures() {
	let mut event: PancakeDriverEvent = unsafe { core::mem::zeroed() };
	event.kind = u32::MAX;
	let error = decode_event(&event).err().expect("unknown event is rejected");
	assert_eq!(error.code(), sys::ERR_INTERNAL);

	event.kind = sys::DRIVER_EVENT_COMPLETION;
	event.action.kind = u32::MAX;
	let error = decode_event(&event).err().expect("unknown completion is rejected");
	assert_eq!(error.code(), sys::ERR_INTERNAL);
}

#[cfg(feature = "tcp")]
fn seed(byte: u8) -> [u8; 64] {
	let mut material = [byte; 64];
	for half in material[32..].iter_mut() {
		*half = byte ^ 0xa5;
	}
	material
}

#[cfg(feature = "tcp")]
fn wait_listener_ready(lp: &DriverLoop, listener: u64) {
	for _ in 0..1_000 {
		for event in lp.step(20).unwrap().unwrap_or_default() {
			match event {
				LoopEvent::ListenerReady { listener: ready } if ready == listener => return,
				LoopEvent::ListenerFailed {
					listener: failed,
					failure,
				} if failed == listener => panic!("listener failed: {}", failure.primary_name),
				_ => {}
			}
		}
	}
	panic!("listener setup timed out");
}

#[cfg(feature = "tcp")]
#[test]
fn failed_park_admission_does_not_publish_a_started_loop() {
	let lp = LoopShared::open(sys::DRIVER_DEFAULT_HANDSHAKE_MS, sys::DRIVER_DEFAULT_SETTLE_MS).unwrap();
	let refused = lp.ensure_started().unwrap_err();
	assert_eq!(refused.kind(), crate::ErrorKind::Internal);
	assert!(!lp.parked.get(), "a refused LocalSet spawn remains retryable");

	let runtime = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.expect("current-thread runtime");
	let local = tokio::task::LocalSet::new();
	local.block_on(&runtime, async {
		lp.ensure_started().unwrap();
		assert!(lp.parked.get());
		lp.close();
		while !lp.released.get() {
			tokio::task::yield_now().await;
		}
	});
}

/// A handshake deadline is a clock edge, not descriptor readiness. The
/// async loop must therefore ask the native driver when its next progress
/// step is due; otherwise a partner that accepts TCP and says nothing can
/// leave this future parked forever.
#[cfg(feature = "tcp")]
#[tokio::test]
async fn a_silent_loop_dial_reaches_its_native_handshake_deadline() {
	let local = tokio::task::LocalSet::new();
	local
		.run_until(async {
			let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
			let port = listener.local_addr().unwrap().port();

			let lp = LoopShared::open(50, sys::DRIVER_DEFAULT_SETTLE_MS).unwrap();
			let netlayer = crate::tcp::Netlayer::new(crate::tcp::Config::default()).unwrap();
			lp.add_provider(netlayer.transport_provider().unwrap()).unwrap();
			let locator_uri = crate::uri::format_peer_locator("tcp", &format!("127.0.0.1:{port}"), "").unwrap();
			let locator = crate::uri::parse_locator(&locator_uri).unwrap();

			let error = tokio::time::timeout(std::time::Duration::from_secs(1), lp.dial_locator(&locator, None))
				.await
				.expect("the native handshake deadline must wake the loop")
				.expect_err("a silent partner must not open a session");
			assert_eq!(error.kind(), crate::ErrorKind::TimedOut);
			lp.close();
		})
		.await;
}

#[cfg(feature = "tcp")]
#[test]
fn refused_background_step_is_terminal_and_observable() {
	let lp = LoopShared::open(sys::DRIVER_DEFAULT_HANDSHAKE_MS, sys::DRIVER_DEFAULT_SETTLE_MS).unwrap();
	lp.schedule_step();
	let retained = lp.terminal_failure.borrow().clone().unwrap();
	assert_eq!(retained.code(), sys::ERR_INTERNAL);
	assert!(retained.to_string().contains("running LocalSet"), "{retained}");
	assert!(
		lp.released.get(),
		"terminal background failure releases the driver loop"
	);
	assert_eq!(lp.guard_handle().unwrap_err().kind(), crate::ErrorKind::Internal);
}

#[cfg(feature = "tcp")]
#[test]
fn dropped_listener_setup_retires_a_committed_ready_listener() {
	let lp = LoopShared::open(sys::DRIVER_DEFAULT_HANDSHAKE_MS, sys::DRIVER_DEFAULT_SETTLE_MS).unwrap();
	let netlayer = crate::tcp::Netlayer::new(crate::tcp::Config::default()).unwrap();
	lp.add_provider(netlayer.transport_provider().unwrap()).unwrap();

	let listener = lp.driver.listen("tcp", "127.0.0.1:0").unwrap();
	let (waiter, _outcome) = oneshot::channel();
	lp.pending_listeners.borrow_mut().insert(listener, waiter);
	let pending = PendingListenerSetup {
		lp: Rc::clone(&lp),
		listener,
		armed: true,
	};
	lp.dispatch(lp.driver.drain_events().unwrap());
	assert!(lp.listeners.borrow().contains(&listener));

	drop(pending);
	assert!(!lp.listeners.borrow().contains(&listener));
	assert!(!lp.pending_listeners.borrow().contains_key(&listener));
	assert!(lp.driver.listener_locator(listener).is_err());
	lp.close();
}

/// The loop tier from Rust (ADR-0112): two stepping loops over loopback
/// TCP, the server driven wholly by its own thread, dial as an operation id, the
/// session as an Opened event, and a vow's break as a Completion event —
/// the byte-fed drain's own Fail shape, ticket-matched. The success arm
/// rides the live iroh parity test below.
#[cfg(feature = "tcp")]
#[test]
fn tcp_loopback_steps_dial_fetch_and_hangup() {
	let stop = Arc::new(AtomicBool::new(false));
	let (designator_tx, designator_rx) = mpsc::channel::<String>();
	let stop_thread = Arc::clone(&stop);
	let server = std::thread::spawn(move || {
		let lp = DriverLoop::open(
			&seed(0x61),
			DriverLoopOptions {
				wire_buffer_bytes: 1024,
				max_pending_opens: 8,
				..DriverLoopOptions::default()
			},
		)
		.unwrap();
		let netlayer = crate::tcp::Netlayer::new(crate::tcp::Config::default()).unwrap();
		lp.add_provider(netlayer.transport_provider().unwrap()).unwrap();
		let listener = lp.listen("tcp", "127.0.0.1:0").unwrap();
		wait_listener_ready(&lp, listener);
		lp.select_listener(listener).unwrap();
		let locator = lp.listener_locator(listener).unwrap();
		designator_tx.send(locator.designator).unwrap();
		while !stop_thread.load(Ordering::Acquire) {
			for event in lp.step(20).unwrap().unwrap_or_default() {
				if let LoopEvent::Accepted { session, .. } = event {
					lp.session_serve(session).unwrap();
				}
			}
		}
	});
	let designator = designator_rx.recv().unwrap();

	let lp = DriverLoop::open(
		&seed(0x62),
		DriverLoopOptions {
			wire_buffer_bytes: 1024,
			..DriverLoopOptions::default()
		},
	)
	.unwrap();
	let netlayer = crate::tcp::Netlayer::new(crate::tcp::Config::default()).unwrap();
	lp.add_provider(netlayer.transport_provider().unwrap()).unwrap();
	let locator_uri = crate::uri::format_peer_locator("tcp", &designator, "").unwrap();
	let locator = crate::uri::parse_locator(&locator_uri).unwrap();
	let operation_id = lp.dial(&locator, None).unwrap();
	let mut session: *mut ffi_host::PancakeHostSession = core::ptr::null_mut();
	'dial: for _ in 0..1000 {
		for event in lp.step(20).unwrap().unwrap_or_default() {
			match event {
				LoopEvent::Opened {
					operation_id: opened_id,
					session: s,
				} => {
					assert_eq!(opened_id, operation_id);
					session = s;
					break 'dial;
				}
				LoopEvent::OpenFailed { failure, .. } => panic!("dial failed: {}", failure.primary_name),
				_ => {}
			}
		}
	}
	assert!(!session.is_null(), "the dial never completed");
	lp.session_serve(session).unwrap();

	let mut vow = 0u64;
	let name = b"nobody-home";
	let rc = unsafe { ffi_host::pancake_host_session_fetch(session, name.as_ptr(), name.len(), &mut vow) };
	assert_eq!(rc, sys::OK);
	let mut broke = false;
	'fetch: for _ in 0..1000 {
		for event in lp.step(20).unwrap().unwrap_or_default() {
			if let LoopEvent::Completion(HostAction::Fail { ticket: t, .. }) = event {
				assert_eq!(t, vow);
				broke = true;
				break 'fetch;
			}
		}
	}
	assert!(broke, "the fetch's break never arrived as a loop event");
	lp.session_release(session).unwrap();
	stop.store(true, Ordering::Release);
	server.join().unwrap();
}

/// Loop-tier FINISH (ADR-0114), mirroring the byte-fed Host timeout
/// scenario in `host.rs`: a dial still negotiating against a silent TCP
/// partner is admitted pending work, so a finite grace expires and the
/// loop close barrier reports its timeout. The expiry takes effect only
/// inside a step, so this is the proof of the close driver's deadline
/// timer: parked on loop activity alone it would never step again.
#[cfg(feature = "tcp")]
#[tokio::test]
async fn a_finite_finish_close_times_out_over_a_negotiating_loop_dial() {
	let local = tokio::task::LocalSet::new();
	local
		.run_until(async {
			// Bound but never accepted from: the kernel backlog completes
			// the TCP connect, and the CapTP handshake never answers.
			let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
			let port = listener.local_addr().unwrap().port();

			let lp = LoopShared::open(sys::DRIVER_DEFAULT_HANDSHAKE_MS, sys::DRIVER_DEFAULT_SETTLE_MS).unwrap();
			let netlayer = crate::tcp::Netlayer::new(crate::tcp::Config::default()).unwrap();
			lp.add_provider(netlayer.transport_provider().unwrap()).unwrap();
			let host = crate::host::Host::from_shared(lp.wrapper_host().unwrap());

			let locator_uri = crate::uri::format_peer_locator("tcp", &format!("127.0.0.1:{port}"), "").unwrap();
			let locator = crate::uri::parse_locator(&locator_uri).unwrap();
			let dial = {
				let lp = Rc::clone(&lp);
				tokio::task::spawn_local(async move { lp.dial_locator(&locator, None).await })
			};
			for _ in 0..1_000 {
				if !lp.pending_dials.borrow().is_empty() {
					break;
				}
				tokio::task::yield_now().await;
			}
			assert!(!lp.pending_dials.borrow().is_empty(), "the dial was never admitted");

			let error = host
				.close(crate::PendingWork::Finish {
					grace: Some(std::time::Duration::from_millis(20)),
				})
				.await
				.expect_err("a negotiating dial keeps the finite finish from settling in time");
			assert_eq!(error.kind(), crate::ErrorKind::TimedOut);
			assert!(dial.await.unwrap().is_err(), "close failed the admitted dial");
		})
		.await;
}

/// The live parity proof (`zig build rust-iroh-driver-provider`): the
/// binding's native-loop iroh listener serves while a second loop dials the
/// same endpoint through the C multiplexed-transport table, and the fetch's
/// settle arrives as a Completion event in the byte-fed Settle shape.
#[test]
#[ignore = "live iroh QUIC; run via `zig build rust-iroh-driver-provider`"]
#[cfg(feature = "iroh")]
fn iroh_provider_dials_live() {
	use crate::iroh::Reachability;
	use crate::iroh::{listen, Config, ListenOptions, Netlayer};
	use crate::{Argument, Session};
	use std::rc::Rc;

	let runtime = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.unwrap();
	let local = tokio::task::LocalSet::new();
	runtime.block_on(local.run_until(async move {
		let server = Rc::new(
			listen(Config::new(Reachability::LocalDiscovery), ListenOptions::default())
				.await
				.unwrap(),
		);
		let node_id = server.node_id().to_string();
		// Host-wide, before any accept: a loop client's fetch can land the
		// instant the handshake opens, so a per-session publish inside the
		// accept task would race it.
		server
			.host()
			.publish_giftable("greeter", || Box::new(|_verb, _args| Ok(Argument::Symbol("hi".into()))))
			.unwrap();
		let accept_server = Rc::clone(&server);
		let accept_task = tokio::task::spawn_local(async move {
			let mut served: Vec<Session> = Vec::new();
			while let Ok(session) = accept_server.accept().await {
				served.push(session);
			}
			served
		});

		// The client half lives wholly on its own OS thread: its own
		// runtime for the netlayer constructor, then plain stepping —
		// so a client step parked on its timeout never starves this
		// serving thread.
		let (done_tx, done_rx) = mpsc::channel::<std::result::Result<(), String>>();
		std::thread::spawn(move || {
			let outcome = (|| -> std::result::Result<(), String> {
				let client_rt = tokio::runtime::Builder::new_current_thread()
					.enable_all()
					.build()
					.map_err(|e| e.to_string())?;
				let netlayer = client_rt
					.block_on(Netlayer::from_seed(
						Config::new(Reachability::LocalDiscovery),
						[0x63u8; 32],
					))
					.map_err(|e| e.to_string())?;
				let provider = netlayer.transport_provider().map_err(|e| e.to_string())?;
				let lp = DriverLoop::open(
					&seed(0x63),
					DriverLoopOptions {
						handshake_ms: 20_000,
						settle_ms: 20_000,
						..DriverLoopOptions::default()
					},
				)
				.map_err(|e| e.to_string())?;
				lp.add_provider(provider).map_err(|e| e.to_string())?;
				let locator_uri = crate::uri::format_peer_locator("iroh", &node_id, "").map_err(|e| e.to_string())?;
				let locator = crate::uri::parse_locator(&locator_uri).map_err(|e| e.to_string())?;
				let operation_id = lp.dial(&locator, None).map_err(|e| e.to_string())?;
				let mut session: *mut ffi_host::PancakeHostSession = core::ptr::null_mut();
				'dial: for _ in 0..2000 {
					for event in lp.step(20).map_err(|e| e.to_string())?.unwrap_or_default() {
						match event {
							LoopEvent::Opened {
								operation_id: opened_id,
								session: s,
							} => {
								if opened_id != operation_id {
									return Err("operation id mismatch".into());
								}
								session = s;
								break 'dial;
							}
							LoopEvent::OpenFailed { failure, .. } => {
								return Err(format!("dial failed: {}", failure.primary_name));
							}
							_ => {}
						}
					}
				}
				if session.is_null() {
					return Err("the dial never completed".into());
				}
				let mut vow = 0u64;
				let name = b"greeter";
				let rc = unsafe { ffi_host::pancake_host_session_fetch(session, name.as_ptr(), name.len(), &mut vow) };
				if rc != sys::OK {
					return Err(format!("fetch refused: {rc}"));
				}
				let mut settled = false;
				'fetch: for _ in 0..2000 {
					for event in lp.step(20).map_err(|e| e.to_string())?.unwrap_or_default() {
						match event {
							LoopEvent::Completion(HostAction::Settle { ticket: t, .. }) => {
								if t != vow {
									return Err("settle ticket mismatch".into());
								}
								settled = true;
								break 'fetch;
							}
							LoopEvent::Completion(HostAction::Fail { message, .. }) => {
								return Err(format!("fetch broke: {message}"));
							}
							_ => {}
						}
					}
				}
				if !settled {
					return Err("the settle never arrived as a loop event".into());
				}
				lp.session_release(session).map_err(|e| e.to_string())?;
				Ok(())
			})();
			let _ = done_tx.send(outcome);
		});

		let outcome = tokio::task::spawn_blocking(move || done_rx.recv())
			.await
			.unwrap()
			.unwrap();
		outcome.unwrap();
		server.close().await.unwrap();
		let _ = accept_task.await;
	}));
}
