//! Endpoint-barrier scenarios that cross the private runtime and the C seam.

use crate::tests::{direct_endpoint, free_endpoint};
use crate::{GlowcapIrohEndpoint, teardown_status};

fn set_nonblocking(endpoint: *mut GlowcapIrohEndpoint, conn: *mut crate::GlowcapIrohConn) -> i32 {
	unsafe { crate::glowcap_iroh_sidecar_conn_set_nonblocking(endpoint, conn) }
}

fn try_write(conn: *mut crate::GlowcapIrohConn, bytes: &[u8]) -> isize {
	unsafe { crate::glowcap_iroh_sidecar_conn_try_write(conn, bytes.as_ptr(), bytes.len()) }
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
	let client_ref = unsafe { &*client };
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
	let client_ref = unsafe { &*client };
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
