//! Endpoint-barrier scenarios that cross the private runtime and the C seam.

use crate::tests::direct_endpoint;
use crate::{glowcap_iroh_sidecar_endpoint_free, teardown_status, GlowcapIrohEndpoint};

#[test]
fn teardown_panics_become_failures() {
	assert_eq!(teardown_status(|| Ok(())), 0);
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
		assert_eq!(glowcap_iroh_sidecar_endpoint_free(raw as *mut GlowcapIrohEndpoint), 0);
	});
}

#[test]
fn peer_close_before_writer_observes_local_close_does_not_fail_endpoint_release() {
	use crate::conn::glowcap_iroh_sidecar_conn_free;
	use crate::nonblocking::{glowcap_iroh_sidecar_conn_set_nonblocking, glowcap_iroh_sidecar_conn_try_write};
	use crate::{make_conn, AcceptedRaw, ALPN};

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
	assert_eq!(glowcap_iroh_sidecar_conn_set_nonblocking(client, conn), 0);
	// The application has not closed its handle yet. This write observes the
	// remote close first, exactly the ordering a runtime/session race permits.
	assert_eq!(glowcap_iroh_sidecar_conn_try_write(conn, b"late".as_ptr(), 4), 4);
	let writer_result = client_ref.writers.wait();
	assert_eq!(glowcap_iroh_sidecar_conn_try_write(conn, b"x".as_ptr(), 1), -1);
	glowcap_iroh_sidecar_conn_free(conn);
	let client_result = glowcap_iroh_sidecar_endpoint_free(client);
	let server_result = glowcap_iroh_sidecar_endpoint_free(server);
	assert_eq!(writer_result, Ok(()));
	assert_eq!(client_result, 0);
	assert_eq!(server_result, 0);
}

#[test]
fn nonblocking_release_delivers_the_complete_admitted_tail() {
	use crate::conn::glowcap_iroh_sidecar_conn_free;
	use crate::nonblocking::{glowcap_iroh_sidecar_conn_set_nonblocking, glowcap_iroh_sidecar_conn_try_write};
	use crate::{make_conn, AcceptedRaw, ALPN};
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
		assert_eq!(glowcap_iroh_sidecar_conn_set_nonblocking(client, handle), 0);
		let tail = vec![0x5a; 64 * 1024];
		assert_eq!(
			glowcap_iroh_sidecar_conn_try_write(handle, tail.as_ptr(), tail.len()),
			tail.len() as isize
		);
		glowcap_iroh_sidecar_conn_free(handle);
		let received = server_ref.rt.block_on(async {
			tokio::time::timeout(std::time::Duration::from_secs(5), receive.read_to_end(tail.len()))
				.await
				.unwrap()
		});
		assert_eq!(received.unwrap(), tail, "release discarded admitted bytes");
		drop(remote);
	}
	assert_eq!(glowcap_iroh_sidecar_endpoint_free(client), 0);
	assert_eq!(glowcap_iroh_sidecar_endpoint_free(server), 0);
}
