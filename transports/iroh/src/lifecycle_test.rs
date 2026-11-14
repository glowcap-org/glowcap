//! Endpoint-barrier scenarios that cross the private runtime and the C seam.

use crate::GlowcapIrohEndpoint;
use crate::tests::{direct_endpoint, free_endpoint, handle};

fn set_nonblocking(endpoint: &GlowcapIrohEndpoint, conn: *mut crate::GlowcapIrohConn) -> i32 {
	// SAFETY: `endpoint` is borrowed for the call, and the callers pass a connection `make_conn` minted from it, freed
	// only after the call.
	unsafe { crate::nonblocking::calls::glowcap_iroh_sidecar_conn_set_nonblocking(handle(endpoint), conn) }
}

fn try_write(conn: *mut crate::GlowcapIrohConn, bytes: &[u8]) -> isize {
	// SAFETY: the wrapper forwards `conn` unchanged, which its callers take from `make_conn` and free only after the
	// call; `bytes` is a borrowed slice, so its pointer and length are live for the call, and the callee copies the
	// admitted prefix into its own outbound buffer.
	unsafe { crate::nonblocking::calls::glowcap_iroh_sidecar_conn_try_write(conn, bytes.as_ptr(), bytes.len()) }
}

/// A partner that stopped this stream or closed the connection takes no more
/// bytes, which is backpressure rather than a fault: no write fails and no bare
/// `EV_CLOSED` reports a lost connection. The departure is the reader's to
/// report, after the partner's last bytes.
fn assert_departure_left_to_reader(endpoint: &GlowcapIrohEndpoint, conn: *mut crate::GlowcapIrohConn) {
	assert_eq!(try_write(conn, b"x"), crate::WOULD_BLOCK);
	let mut ready = [crate::GlowcapIrohReadyEvent::from((0, 0)); 16];
	// SAFETY: `endpoint` is borrowed for the call, and `ready` is a writable array of the capacity passed.
	let drained = unsafe {
		crate::nonblocking::calls::glowcap_iroh_sidecar_endpoint_drain_ready(
			handle(endpoint),
			ready.as_mut_ptr(),
			ready.len(),
		)
	};
	assert!(drained >= 0);
	for event in &ready[..drained as usize] {
		assert!(event.events & crate::EV_CLOSED == 0 || event.events & crate::EV_READABLE != 0);
	}
}

#[test]
fn endpoint_release_is_safe_inside_an_ambient_tokio_runtime() {
	let endpoint = direct_endpoint(100);
	let ambient = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.unwrap();
	ambient.block_on(async move {
		assert_eq!(free_endpoint(endpoint), 0);
	});
}

#[test]
fn peer_close_before_writer_observes_local_close_does_not_fail_endpoint_release() {
	use crate::conn::glowcap_iroh_sidecar_conn_free;
	use crate::{ALPN, AcceptedRaw, make_conn};

	let client = direct_endpoint(5_000);
	let server = direct_endpoint(5_000);
	let raw = client.rt.block_on(async {
		let (dialed, accepted) = tokio::join!(client.ep.connect(server.ep.addr(), ALPN), async {
			server.ep.accept().await.unwrap().await.unwrap()
		});
		let dialed = dialed.unwrap();
		let (mut send, recv) = dialed.open_bi().await.unwrap();
		send.write_all(b"open").await.unwrap();
		let (_send, _recv) = accepted.accept_bi().await.unwrap();
		accepted.close(0u32.into(), b"");
		assert!(matches!(
			dialed.closed().await,
			crate::ConnectionError::ApplicationClosed(_)
		));
		AcceptedRaw {
			conn: dialed,
			send,
			recv,
		}
	});
	let conn = make_conn(&client, raw).unwrap();
	assert_eq!(set_nonblocking(&client, conn), 0);
	// The application has not closed its handle yet. This write observes the
	// remote close first, exactly the ordering a runtime/session race permits.
	assert_eq!(try_write(conn, b"late"), 4);
	let writer_result = client.writers.wait();
	assert_departure_left_to_reader(&client, conn);
	// SAFETY: `conn` is the owned handle `make_conn` returned for this endpoint; nothing has freed it, and it is not
	// used after this call, which runs before either endpoint is freed.
	unsafe { glowcap_iroh_sidecar_conn_free(conn) };
	let client_result = free_endpoint(client);
	let server_result = free_endpoint(server);
	assert_eq!(writer_result, Ok(()));
	assert_eq!(client_result, 0);
	assert_eq!(server_result, 0);
}

#[test]
fn peer_stop_before_writer_observes_local_close_does_not_fail_endpoint_release() {
	use crate::conn::glowcap_iroh_sidecar_conn_free;
	use crate::{ALPN, AcceptedRaw, make_conn};

	let client = direct_endpoint(5_000);
	let server = direct_endpoint(5_000);
	let (raw, remote, reply) = client.rt.block_on(async {
		let (dialed, accepted) = tokio::join!(client.ep.connect(server.ep.addr(), ALPN), async {
			server.ep.accept().await.unwrap().await.unwrap()
		});
		let dialed = dialed.unwrap();
		let (mut send, recv) = dialed.open_bi().await.unwrap();
		send.write_all(b"open").await.unwrap();
		let (reply, receive) = accepted.accept_bi().await.unwrap();
		// The partner stops reading this stream without closing the connection,
		// which is what its reader abort at connection release does.
		drop(receive);
		assert_eq!(send.stopped().await.unwrap(), Some(0u32.into()));
		(
			AcceptedRaw {
				conn: dialed,
				send,
				recv,
			},
			accepted,
			reply,
		)
	});
	let conn = make_conn(&client, raw).unwrap();
	assert_eq!(set_nonblocking(&client, conn), 0);
	// The application has not closed its handle yet. This write observes the
	// partner's stop first, exactly the ordering a loaded server permits.
	assert_eq!(try_write(conn, b"late"), 4);
	let writer_result = client.writers.wait();
	assert_departure_left_to_reader(&client, conn);
	// SAFETY: `conn` is the owned handle `make_conn` returned for this endpoint; nothing has freed it, and it is not
	// used after this call, which runs before either endpoint is freed.
	unsafe { glowcap_iroh_sidecar_conn_free(conn) };
	drop((reply, remote));
	let client_result = free_endpoint(client);
	let server_result = free_endpoint(server);
	assert_eq!(writer_result, Ok(()));
	assert_eq!(client_result, 0);
	assert_eq!(server_result, 0);
}

#[test]
fn nonblocking_release_delivers_the_complete_admitted_tail() {
	use crate::conn::glowcap_iroh_sidecar_conn_free;
	use crate::{ALPN, AcceptedRaw, make_conn};
	let client = direct_endpoint(5_000);
	let server = direct_endpoint(5_000);
	for _ in 0..8 {
		let (raw, remote, mut receive) = client.rt.block_on(async {
			let (dialed, accepted) = tokio::join!(client.ep.connect(server.ep.addr(), ALPN), async {
				server.ep.accept().await.unwrap().await.unwrap()
			});
			let conn = dialed.unwrap();
			let (mut send, recv) = conn.open_bi().await.unwrap();
			send.write_all(b"start").await.unwrap();
			let (reply, mut receive) = accepted.accept_bi().await.unwrap();
			let mut start = [0; 5];
			receive.read_exact(&mut start).await.unwrap();
			drop(reply);
			(AcceptedRaw { conn, send, recv }, accepted, receive)
		});
		let handle = make_conn(&client, raw).unwrap();
		assert_eq!(set_nonblocking(&client, handle), 0);
		let tail = vec![0x5a; 64 * 1024];
		assert_eq!(try_write(handle, &tail), isize::try_from(tail.len()).unwrap());
		// SAFETY: `handle` is the owned handle `make_conn` returned for this iteration; nothing has freed it, and it is
		// not used after this call, which runs before either endpoint is freed.
		unsafe { glowcap_iroh_sidecar_conn_free(handle) };
		let received = server.rt.block_on(async {
			tokio::time::timeout(std::time::Duration::from_secs(5), receive.read_to_end(tail.len()))
				.await
				.unwrap()
		});
		assert_eq!(received.unwrap(), tail, "release discarded admitted bytes");
		drop(remote);
	}
	assert_eq!(free_endpoint(client), 0);
	assert_eq!(free_endpoint(server), 0);
}

/// A partner whose process died sends no close and acknowledges nothing. The
/// local release still completes: the admitted tail after the local close is a
/// bounded farewell, so the partner's silence is not a teardown failure.
#[test]
fn a_vanished_partner_does_not_fail_endpoint_release() {
	use crate::conn::glowcap_iroh_sidecar_conn_free;
	use crate::{ALPN, AcceptedRaw, make_conn};

	// The partner's silence surfaces as this endpoint's idle timeout, so a short
	// one keeps the scenario inside its test deadline.
	let config = crate::GlowcapIrohEndpointConfig {
		reachability: crate::REACH_DIRECT,
		connect_timeout_ms: 5_000,
		idle_timeout_ms: 1_000,
		worker_threads: 0,
	};
	let client = GlowcapIrohEndpoint::bind(None, config).expect("a direct endpoint binds");
	let server = direct_endpoint(5_000);
	let (raw, partner) = client.rt.block_on(async {
		let (dialed, accepted) = tokio::join!(client.ep.connect(server.ep.addr(), ALPN), async {
			server.ep.accept().await.unwrap().await.unwrap()
		});
		let conn = dialed.unwrap();
		let (mut send, recv) = conn.open_bi().await.unwrap();
		send.write_all(b"start").await.unwrap();
		let (reply, mut receive) = accepted.accept_bi().await.unwrap();
		let mut start = [0; 5];
		receive.read_exact(&mut start).await.unwrap();
		(AcceptedRaw { conn, send, recv }, (accepted, reply, receive))
	});
	let conn = make_conn(&client, raw).unwrap();
	assert_eq!(set_nonblocking(&client, conn), 0);
	assert_eq!(try_write(conn, b"tail"), 4);
	// The partner dies: its runtime stops without closing the connection or the
	// endpoint, so nothing more crosses the wire from it.
	std::mem::forget(partner);
	// The partner's endpoint is leaked on purpose so no close is sent.
	let crate::GlowcapIrohEndpoint { ep, rt, .. } = *server;
	std::mem::forget(ep);
	drop(rt);
	// SAFETY: `conn` is the owned handle `make_conn` returned for this endpoint; nothing has freed it, and it is not
	// used after this call, which runs before the endpoint is freed.
	unsafe { glowcap_iroh_sidecar_conn_free(conn) };
	assert_eq!(client.writers.wait(), Ok(()));
	assert_eq!(free_endpoint(client), 0);
}

/// An oversized length is refused at entry: an in-range read of the same empty
/// connection would block.
#[test]
fn oversized_nonblocking_lengths_are_refused_before_any_queue_read() {
	use crate::conn::glowcap_iroh_sidecar_conn_free;
	use crate::nonblocking::calls::{glowcap_iroh_sidecar_conn_try_read, glowcap_iroh_sidecar_conn_try_write};
	use crate::{ALPN, AcceptedRaw, make_conn};

	let client = direct_endpoint(5_000);
	let server = direct_endpoint(5_000);
	// The partner holds its side open, so the in-range read below finds an empty queue rather than a close.
	let (raw, accepted) = client.rt.block_on(async {
		let (dialed, accepted) = tokio::join!(client.ep.connect(server.ep.addr(), ALPN), async {
			server.ep.accept().await.unwrap().await.unwrap()
		});
		let dialed = dialed.unwrap();
		let (send, recv) = dialed.open_bi().await.unwrap();
		(
			AcceptedRaw {
				conn: dialed,
				send,
				recv,
			},
			accepted,
		)
	});
	let conn = make_conn(&client, raw).unwrap();
	assert_eq!(set_nonblocking(&client, conn), 0);
	let oversized = isize::MAX as usize + 1;
	let mut byte = 0u8;
	// SAFETY: `conn` is the live handle `make_conn` returned, and `byte` is a valid local byte. The oversized calls
	// neither read nor write behind it, because they refuse the length before forming a slice.
	unsafe {
		assert_eq!(glowcap_iroh_sidecar_conn_try_read(conn, &mut byte, oversized), -1);
		assert_eq!(glowcap_iroh_sidecar_conn_try_write(conn, &byte, oversized), -1);
		// An in-range read on the same empty inbound queue would block instead.
		assert_eq!(
			glowcap_iroh_sidecar_conn_try_read(conn, &mut byte, 1),
			crate::WOULD_BLOCK
		);
		glowcap_iroh_sidecar_conn_free(conn);
	}
	drop(accepted);
	assert_eq!(client.writers.wait(), Ok(()));
	assert_eq!(free_endpoint(client), 0);
	assert_eq!(free_endpoint(server), 0);
}

/// A blocking connection dialed to a partner whose accepted side holds the
/// stream the connection writes to.
struct Dialed {
	client: Box<GlowcapIrohEndpoint>,
	server: Box<GlowcapIrohEndpoint>,
	conn: *mut crate::GlowcapIrohConn,
	dialed: crate::Connection,
	accepted: crate::Connection,
	partner_send: crate::SendStream,
}

fn dial_blocking() -> Dialed {
	use crate::{ALPN, AcceptedRaw, make_conn};

	let client = direct_endpoint(5_000);
	let server = direct_endpoint(5_000);
	let (dialed, send, recv, accepted) = client.rt.block_on(async {
		let (dialed, accepted) = tokio::join!(client.ep.connect(server.ep.addr(), ALPN), async {
			server.ep.accept().await.unwrap().await.unwrap()
		});
		let dialed = dialed.unwrap();
		let (send, recv) = dialed.open_bi().await.unwrap();
		(dialed, send, recv, accepted)
	});
	let raw = AcceptedRaw {
		conn: dialed.clone(),
		send,
		recv,
	};
	let conn = make_conn(&client, raw).unwrap();
	// A stream is visible to its partner only once bytes cross it.
	// SAFETY: `conn` is the live handle `make_conn` returned, and the buffer is a local array of the length passed.
	let written = unsafe { crate::conn::glowcap_iroh_sidecar_conn_write(conn, b"open".as_ptr(), 4) };
	assert_eq!(written, 4);
	let partner_send = client.rt.block_on(async { accepted.accept_bi().await.unwrap().0 });
	Dialed {
		client,
		server,
		conn,
		dialed,
		accepted,
		partner_send,
	}
}

fn blocking_read(conn: *mut crate::GlowcapIrohConn, buf: &mut [u8]) -> isize {
	// SAFETY: `conn` is a live handle its caller frees after this call, and `buf` is a writable local slice of the
	// length passed.
	unsafe { crate::conn::glowcap_iroh_sidecar_conn_read(conn, buf.as_mut_ptr(), buf.len()) }
}

fn release(dialed: Dialed) {
	// SAFETY: `conn` is the owned handle `make_conn` returned and is not used after this call.
	unsafe { crate::conn::glowcap_iroh_sidecar_conn_free(dialed.conn) };
	drop(dialed.partner_send);
	drop(dialed.accepted);
	assert_eq!(free_endpoint(dialed.client), 0);
	assert_eq!(free_endpoint(dialed.server), 0);
}

#[test]
fn blocking_read_answers_bytes_then_zero_at_a_finished_stream() {
	let mut d = dial_blocking();
	d.client.rt.block_on(async {
		d.partner_send.write_all(b"hi").await.unwrap();
		d.partner_send.finish().unwrap();
	});
	let mut buf = [0u8; 16];
	assert_eq!(blocking_read(d.conn, &mut buf), 2);
	assert_eq!(&buf[..2], b"hi");
	assert_eq!(blocking_read(d.conn, &mut buf), 0);
	release(d);
}

#[test]
fn blocking_read_answers_zero_when_either_side_closes_cleanly() {
	let d = dial_blocking();
	d.accepted.close(0u32.into(), b"");
	assert_eq!(blocking_read(d.conn, &mut [0u8; 4]), 0);
	release(d);

	let d = dial_blocking();
	d.dialed.close(0u32.into(), b"");
	assert_eq!(blocking_read(d.conn, &mut [0u8; 4]), 0);
	release(d);
}

#[test]
fn blocking_read_answers_minus_one_for_a_reset_stream() {
	let mut d = dial_blocking();
	d.partner_send.reset(7u32.into()).unwrap();
	assert_eq!(blocking_read(d.conn, &mut [0u8; 4]), -1);
	release(d);
}
