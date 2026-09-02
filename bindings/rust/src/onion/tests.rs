use super::*;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};

/// A real, checksum-valid version 3 id, from the pinned Goblins source. Using
/// a well-formed one matters: the transport refuses anything else before it
/// opens a socket, so a placeholder would pass these tests for the wrong
/// reason.
const SERVICE_ID: &str = "wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd";

/// Answer one Tor control conversation: `AUTHENTICATE`, then `ADD_ONION`.
///
/// This is a fake, not a Tor. The bytes it accepts are pinned against the
/// pinned Goblins netlayer and the upstream OCapN suite on the Zig side; here
/// it only lets the binding's own surface be exercised with no daemon.
/// Returns the `AUTHENTICATE` line it received, so a test can assert which
/// credential form actually reached the daemon. Without that, a mapping that
/// silently sent no credential would pass every other test here.
fn fake_control(listener: TcpListener) -> String {
	fake_control_reporting(listener, None)
}

/// As `fake_control`, and when `forward` is given, send the forward target the
/// `ADD_ONION` named down it. That target is the local endpoint glowcap bound
/// and told the daemon about, exactly what a test needs to stand in for Tor
/// forwarding a circuit.
fn fake_control_reporting(listener: TcpListener, forward: Option<std::sync::mpsc::Sender<String>>) -> String {
	let mut authenticate = String::new();
	let (mut stream, _) = listener.accept().unwrap();
	let mut pending = Vec::new();
	let mut byte = [0u8; 1];
	loop {
		match stream.read(&mut byte) {
			Ok(0) | Err(_) => return authenticate,
			Ok(_) => {}
		}
		if byte[0] != b'\n' {
			if byte[0] != b'\r' {
				pending.push(byte[0]);
			}
			continue;
		}
		let line = String::from_utf8_lossy(&pending).to_string();
		pending.clear();
		if line.starts_with("AUTHENTICATE") {
			authenticate = line.clone();
		}
		if line.starts_with("ADD_ONION") {
			if let Some(tx) = forward.as_ref() {
				// `PORT=<virtual>,<target>` — the target is what follows the comma.
				if let Some(at) = line.find("PORT=") {
					if let Some(comma) = line[at..].find(',') {
						let _ = tx.send(line[at + comma + 1..].to_string());
					}
				}
			}
		}
		let reply = if line.starts_with("ADD_ONION") {
			format!("250-ServiceID={SERVICE_ID}\r\n250-PrivateKey=ED25519-V3:c3RvcmVk\r\n250 OK\r\n")
		} else {
			"250 OK\r\n".to_string()
		};
		if stream.write_all(reply.as_bytes()).is_err() {
			return authenticate;
		}
	}
}

/// Answer one SOCKS5 handshake for `SERVICE_ID` and return the stream, which
/// is then an ordinary byte pipe — exactly what a circuit is once the reply is
/// out.
fn fake_socks(listener: TcpListener) -> TcpStream {
	let (mut stream, _) = listener.accept().unwrap();
	let mut greeting = [0u8; 3];
	stream.read_exact(&mut greeting).unwrap();
	assert_eq!(greeting, [0x05, 0x01, 0x00]);
	stream.write_all(&[0x05, 0x00]).unwrap();

	// Four header bytes, the length byte, the 62-character address, and the
	// two-byte port.
	let mut request = [0u8; 69];
	stream.read_exact(&mut request).unwrap();
	assert_eq!(&request[..5], &[0x05, 0x01, 0x00, 0x03, 62]);
	assert_eq!(&request[5..5 + 56], SERVICE_ID.as_bytes());
	assert_eq!(&request[5 + 56..5 + 62], b".onion");
	// 9045, big-endian.
	assert_eq!(&request[67..], &[0x23, 0x55]);

	stream.write_all(&[0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).unwrap();
	stream
}

fn loopback() -> (TcpListener, String) {
	let listener = TcpListener::bind("127.0.0.1:0").unwrap();
	let address = listener.local_addr().unwrap().to_string();
	(listener, address)
}

#[test]
#[cfg(feature = "async")]
fn high_level_listener_projects_driver_locator_and_restoration_key() {
	let (control_listener, control) = loopback();
	let daemon = std::thread::spawn(move || fake_control(control_listener));
	let runtime = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.unwrap();
	let local = tokio::task::LocalSet::new();
	local.block_on(&runtime, async {
		let config = Config::dial_only("127.0.0.1:1").with_control(&control, Auth::None);
		let server = listen(config, ListenOptions::default()).await.unwrap();

		let locator = server.locator().unwrap();
		assert_eq!(locator.transport, "onion");
		assert_eq!(locator.designator, SERVICE_ID);
		assert!(locator.hints.is_empty());
		assert_eq!(server.service_id().unwrap(), SERVICE_ID);
		assert_eq!(server.uri().unwrap(), format!("ocapn://{SERVICE_ID}.onion"));
		assert_eq!(server.service_key(), b"ED25519-V3:c3RvcmVk");

		server.close().await.unwrap();
		let accepted = server.accept().await;
		assert_eq!(accepted.err().map(|err| err.code()), Some(crate::sys::ERR_CLOSED));
	});
	drop(runtime);
	assert_eq!(daemon.join().unwrap(), "AUTHENTICATE");
}

#[test]
#[cfg(feature = "async")]
fn caller_owned_host_survives_onion_listener_close() {
	let (control_listener, control) = loopback();
	let daemon = std::thread::spawn(move || fake_control(control_listener));
	let runtime = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.unwrap();
	let local = tokio::task::LocalSet::new();
	local.block_on(&runtime, async {
		let host = crate::Host::from_seed([0x73; 32]).unwrap();
		let config = Config::dial_only("127.0.0.1:1").with_control(&control, Auth::None);
		let server = listen(
			config,
			ListenOptions {
				identity: ListenerIdentity::Host(host.clone()),
			},
		)
		.await
		.unwrap();
		server.close().await.unwrap();
		assert!(host.designator().is_ok());
		drop(server);
		host.close(crate::PendingWork::Cancel).await.unwrap();
	});
	drop(runtime);
	assert_eq!(daemon.join().unwrap(), "AUTHENTICATE");
}

#[test]
#[cfg(feature = "async")]
fn caller_owned_host_rejects_incompatible_onion_provider_config() {
	let (control_listener, control) = loopback();
	let daemon = std::thread::spawn(move || fake_control(control_listener));
	let runtime = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.unwrap();
	let local = tokio::task::LocalSet::new();
	local.block_on(&runtime, async {
		let host = crate::Host::from_seed([0x74; 32]).unwrap();
		let config = Config::dial_only("127.0.0.1:1").with_control(&control, Auth::None);
		let server = listen(
			config,
			ListenOptions {
				identity: ListenerIdentity::Host(host.clone()),
			},
		)
		.await
		.unwrap();
		server.close().await.unwrap();

		let incompatible = Config::dial_only("127.0.0.1:1")
			.with_control(&control, Auth::None)
			.with_forward("127.0.0.1:2");
		let result = listen(
			incompatible,
			ListenOptions {
				identity: ListenerIdentity::Host(host.clone()),
			},
		)
		.await;
		assert_eq!(
			result.err().map(|err| err.code()),
			Some(crate::sys::ERR_INVALID_ARGUMENT)
		);

		host.close(crate::PendingWork::Cancel).await.unwrap();
	});
	drop(runtime);
	assert_eq!(daemon.join().unwrap(), "AUTHENTICATE");
}

#[test]
#[cfg(feature = "async")]
fn provider_registration_outlives_its_construction_reference() {
	let (control_listener, control) = loopback();
	let daemon = std::thread::spawn(move || fake_control(control_listener));
	let config = Config::dial_only("127.0.0.1:1").with_control(&control, Auth::None);
	let driver = crate::driver_loop::DriverLoop::open(
		&[0x71; 64],
		crate::driver_loop::DriverLoopOptions {
			handshake_ms: 1_000,
			settle_ms: 1_000,
			..crate::driver_loop::DriverLoopOptions::default()
		},
	)
	.unwrap();

	install_provider(&driver, &config).unwrap();
	assert!(driver.has_transport("onion").unwrap());
	let listener = driver.listen("onion", "").unwrap();
	'ready: for attempt in 0..1_000 {
		for event in driver.step(20).unwrap().unwrap_or_default() {
			match event {
				crate::driver_loop::LoopEvent::ListenerReady { listener: ready } if ready == listener => {
					break 'ready;
				}
				crate::driver_loop::LoopEvent::ListenerFailed {
					listener: failed,
					failure,
				} if failed == listener => panic!("listener failed: {}", failure.primary_name),
				_ => {}
			}
		}
		if attempt == 999 {
			panic!("listener setup timed out");
		}
	}
	let locator = driver.listener_locator(listener).unwrap();
	assert_eq!(locator.transport, "onion");
	assert_eq!(locator.designator, SERVICE_ID);
	driver.close_listener(listener).unwrap();
	drop(driver);
	assert_eq!(daemon.join().unwrap(), "AUTHENTICATE");
}

// A dial through the SOCKS endpoint carries a frame, proving the `onion`
// archive composes with the core exactly as the tcp and inproc ones do.
#[test]
fn shuttles_a_frame_over_a_dialed_circuit() {
	// What reaches the wire is the frame inside its netstring envelope: a
	// Syrup byte string whose length prefix the reader strips again. Asserting
	// the framed form rather than the bare payload is what makes this a
	// transport proof instead of a memcpy proof.
	const PAYLOAD: &[u8] = b"<8'op:abort3\"bye>";
	let framed: Vec<u8> = format!("{}:", PAYLOAD.len())
		.into_bytes()
		.into_iter()
		.chain(PAYLOAD.iter().copied())
		.collect();

	let (socks_listener, socks) = loopback();
	let expected_len = framed.len();
	let far = std::thread::spawn(move || {
		let mut stream = fake_socks(socks_listener);
		let mut got = vec![0u8; expected_len];
		stream.read_exact(&mut got).unwrap();
		got
	});

	let netlayer = Netlayer::new(&Config::dial_only(&socks)).unwrap();
	let mut conn = netlayer.connect(SERVICE_ID, Codec::Syrup, 4096).unwrap();
	conn.write_frame(PAYLOAD).unwrap();

	assert_eq!(far.join().unwrap(), framed);
}

// Hosting reports the id the daemon named and the key that restores it.
#[test]
fn listening_reports_the_service_tor_named() {
	let (control_listener, control) = loopback();
	let daemon = std::thread::spawn(move || fake_control(control_listener));

	let config = Config::dial_only("127.0.0.1:1").with_control(&control, Auth::None);
	let netlayer = Netlayer::new(&config).unwrap();
	let listener = netlayer.listen().unwrap();

	assert_eq!(listener.service_id(), SERVICE_ID);
	assert_eq!(listener.service_key(), b"ED25519-V3:c3RvcmVk");
	// Nothing has dialed, so the wait expires rather than parking.
	assert!(!listener.wait(1).unwrap());

	drop(listener);
	drop(netlayer);
	assert_eq!(daemon.join().unwrap(), "AUTHENTICATE");
}

/// Drive one `listen` against a fake daemon and report the `AUTHENTICATE` line
/// the daemon saw.
fn authenticate_line_for(auth: Auth<'_>) -> String {
	let (control_listener, control) = loopback();
	let daemon = std::thread::spawn(move || fake_control(control_listener));
	let config = Config::dial_only("127.0.0.1:1").with_control(&control, auth);
	{
		let netlayer = Netlayer::new(&config).unwrap();
		let listener = netlayer.listen().unwrap();
		drop(listener);
	}
	daemon.join().unwrap()
}

// Each credential form reaches the daemon as its own request. This is the test
// that catches a mapping which sends no credential at all: every other test
// here uses an unauthenticated endpoint, where that mistake looks like success.
#[test]
fn each_auth_form_reaches_the_daemon_as_itself() {
	// Goblins' form: the bare keyword, no credential.
	assert_eq!(authenticate_line_for(Auth::None), "AUTHENTICATE");
	// A cookie file's bytes, as hexadecimal.
	assert_eq!(
		authenticate_line_for(Auth::Cookie(&[0x00, 0x01, 0x0f, 0xff])),
		"AUTHENTICATE 00010fff"
	);
	// A password, as a quoted string.
	assert_eq!(
		authenticate_line_for(Auth::Password("hunter2")),
		"AUTHENTICATE \"hunter2\""
	);
}

// The readiness descriptor is the point of the whole surface: it must be a real,
// pollable socket that reports "nothing yet" before a partner arrives and
// "readable" after one does. A test that only asserted the number was non-negative
// would pass on a descriptor pointing at anything at all.
#[test]
fn the_listener_descriptor_reports_arrival_without_blocking() {
	let (control_listener, control) = loopback();
	let (tx, rx) = std::sync::mpsc::channel();
	let daemon = std::thread::spawn(move || fake_control_reporting(control_listener, Some(tx)));

	let config = Config::dial_only("127.0.0.1:1").with_control(&control, Auth::None);
	let netlayer = Netlayer::new(&config).unwrap();
	let listener = netlayer.listen().unwrap();
	let fd = listener.readiness_fd().unwrap();
	assert!(fd >= 0);

	// The descriptor must be the live accept socket, not merely a non-negative
	// number. Duplicating it and asking for a non-blocking accept proves both
	// halves: `WouldBlock` says it is a listening socket with nothing pending.
	// The duplicate is what keeps the listener's own descriptor intact.
	let probe = {
		use std::os::fd::{AsRawFd, BorrowedFd};
		let owned = unsafe { BorrowedFd::borrow_raw(fd) }.try_clone_to_owned().unwrap();
		let probe = TcpListener::from(owned);
		probe.set_nonblocking(true).unwrap();
		assert_eq!(probe.accept().unwrap_err().kind(), std::io::ErrorKind::WouldBlock);
		assert!(probe.as_raw_fd() != fd);
		probe
	};

	// Stand in for Tor forwarding a circuit: connect to the local endpoint the
	// listener bound and told the daemon about.
	let target = rx.recv().unwrap();
	let _circuit = TcpStream::connect(&target).unwrap();

	// Now readiness reports arrival on that same descriptor, and `accept`
	// returns instead of parking.
	assert!(listener.wait(1000).unwrap());
	let conn = listener.accept(Codec::Syrup, 4096).unwrap();
	// The connection has its own pollable descriptor too.
	assert!(conn.readiness_fd().unwrap() >= 0);

	drop(probe);
	drop(conn);
	drop(listener);
	drop(netlayer);
	let _ = daemon.join();
}

// A netlayer with no control endpoint can dial and cannot host, and says so
// rather than reporting a service nothing could reach.
#[test]
fn a_dial_only_netlayer_refuses_to_host() {
	let netlayer = Netlayer::new(&Config::dial_only("127.0.0.1:1")).unwrap();
	// `Listener` is not `Debug` (an opaque handle), so match rather than
	// `unwrap_err`, and bind the code out so the temporary `Result` drops
	// before the netlayer it borrows.
	let code = match netlayer.listen() {
		Ok(_) => panic!("a dial-only netlayer should not host"),
		Err(err) => err.code(),
	};
	assert_ne!(code, crate::sys::OK);
}

// A designator that is not a well-formed version 3 address is refused before
// any socket opens. The SOCKS endpoint here is a port nothing listens on, so a
// check that ran later would report a connection failure instead.
#[test]
fn a_malformed_designator_is_refused_before_dialing() {
	let netlayer = Netlayer::new(&Config::dial_only("127.0.0.1:1")).unwrap();
	let code = match netlayer.connect("not-an-onion-address", Codec::Syrup, 4096) {
		Ok(_) => panic!("a malformed designator should be refused"),
		Err(err) => err.code(),
	};
	assert_ne!(code, crate::sys::OK);
}
