//! Endpoint-barrier scenarios that cross the private runtime and the C seam.

use crate::tests::{direct_endpoint, free_endpoint};
use crate::{GlowcapIrohEndpoint, teardown_status};

fn set_nonblocking(endpoint: *mut GlowcapIrohEndpoint, conn: *mut crate::GlowcapIrohConn) -> i32 {
	// SAFETY: the wrapper forwards its arguments unchanged; its callers pass the live endpoint from `direct_endpoint`
	// and a connection `make_conn` minted from that endpoint, both freed only after the call.
	unsafe { crate::nonblocking::calls::glowcap_iroh_sidecar_conn_set_nonblocking(endpoint, conn) }
}

fn try_write(conn: *mut crate::GlowcapIrohConn, bytes: &[u8]) -> isize {
	// SAFETY: the wrapper forwards `conn` unchanged, which its callers take from `make_conn` and free only after the
	// call; `bytes` is a borrowed slice, so its pointer and length are live for the call, and the callee copies the
	// admitted prefix into its own outbound buffer.
	unsafe { crate::nonblocking::calls::glowcap_iroh_sidecar_conn_try_write(conn, bytes.as_ptr(), bytes.len()) }
}

#[test]
fn teardown_panics_become_failures() {
	assert_eq!(teardown_status(|| Ok::<(), ()>(())), 0);
	assert_eq!(
		teardown_status(|| -> Result<(), ()> { panic!("forced teardown panic") }),
		-1
	);
}

#[test]
fn endpoint_release_is_safe_inside_an_ambient_tokio_runtime() {
	let endpoint = direct_endpoint(100);
	assert!(!endpoint.is_null());
	let raw = endpoint as usize;
	let ambient = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.unwrap();
	ambient.block_on(async move {
		assert_eq!(free_endpoint(raw as *mut GlowcapIrohEndpoint), 0);
	});
}

#[test]
fn peer_close_before_writer_observes_local_close_does_not_fail_endpoint_release() {
	use crate::conn::glowcap_iroh_sidecar_conn_free;
	use crate::{ALPN, AcceptedRaw, make_conn};

	let client = direct_endpoint(5_000);
	let server = direct_endpoint(5_000);
	assert!(!client.is_null() && !server.is_null());
	// SAFETY: `client` is the non-null live handle `direct_endpoint` returned (asserted above); only the
	// `free_endpoint` calls at the end of this test free it, and `client_ref` is not used after them.
	let client_ref = unsafe { &*client };
	// SAFETY: `server` is the non-null live handle `direct_endpoint` returned (asserted above); only the
	// `free_endpoint` calls at the end of this test free it, and `server_ref` is not used after them.
	let server_ref = unsafe { &*server };
	let raw = client_ref.rt.block_on(async {
		let (dialed, accepted) = tokio::join!(client_ref.ep.connect(server_ref.ep.addr(), ALPN), async {
			server_ref.ep.accept().await.unwrap().await.unwrap()
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
	let conn = make_conn(client_ref, raw).unwrap();
	assert_eq!(set_nonblocking(client, conn), 0);
	// The application has not closed its handle yet. This write observes the
	// remote close first, exactly the ordering a runtime/session race permits.
	assert_eq!(try_write(conn, b"late"), 4);
	let writer_result = client_ref.writers.wait();
	assert_eq!(try_write(conn, b"x"), -1);
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
fn nonblocking_release_delivers_the_complete_admitted_tail() {
	use crate::conn::glowcap_iroh_sidecar_conn_free;
	use crate::{ALPN, AcceptedRaw, make_conn};
	let client = direct_endpoint(5_000);
	let server = direct_endpoint(5_000);
	assert!(!client.is_null() && !server.is_null());
	// SAFETY: as `peer_close_before_writer_observes_local_close_does_not_fail_endpoint_release` above, `client` is the
	// non-null live handle `direct_endpoint` returned and is freed only after the last use of `client_ref`.
	let client_ref = unsafe { &*client };
	// SAFETY: as `peer_close_before_writer_observes_local_close_does_not_fail_endpoint_release` above, `server` is the
	// non-null live handle `direct_endpoint` returned and is freed only after the last use of `server_ref`.
	let server_ref = unsafe { &*server };
	for _ in 0..8 {
		let (raw, remote, mut receive) = client_ref.rt.block_on(async {
			let (dialed, accepted) = tokio::join!(client_ref.ep.connect(server_ref.ep.addr(), ALPN), async {
				server_ref.ep.accept().await.unwrap().await.unwrap()
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
		let handle = make_conn(client_ref, raw).unwrap();
		assert_eq!(set_nonblocking(client, handle), 0);
		let tail = vec![0x5a; 64 * 1024];
		assert_eq!(try_write(handle, &tail), isize::try_from(tail.len()).unwrap());
		// SAFETY: `handle` is the owned handle `make_conn` returned for this iteration; nothing has freed it, and it is
		// not used after this call, which runs before either endpoint is freed.
		unsafe { glowcap_iroh_sidecar_conn_free(handle) };
		let received = server_ref.rt.block_on(async {
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
