//! Real TLS sockets exercise trust, SASL, pacing and physical retirement.
use super::*;
use crate::irc::{Connection, Event};
use rooms_application::server::irc::{
	protocol::encode,
	registration::{Role, SaslPlain},
};
use std::time::Duration;
use tokio::{
	io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
	net::TcpListener,
};
use tokio_rustls::{
	TlsAcceptor,
	rustls::{
		self,
		pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject},
	},
};

fn trust(trusted: bool) -> Tls {
	let mut roots = rustls::RootCertStore::empty();
	if trusted {
		roots
			.add(
				CertificateDer::from_pem_slice(include_bytes!(concat!(
					env!("CARGO_MANIFEST_DIR"),
					"/../../../../test/net/fixtures/tls_root.pem"
				)))
				.unwrap(),
			)
			.unwrap();
	}
	let config = rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
		.with_safe_default_protocol_versions()
		.unwrap()
		.with_root_certificates(roots)
		.with_no_client_auth();
	Tls(TlsConnector::from(Arc::new(config)))
}

fn acceptor() -> TlsAcceptor {
	let cert = CertificateDer::from_pem_slice(include_bytes!(concat!(
		env!("CARGO_MANIFEST_DIR"),
		"/../../../../test/net/fixtures/tls_server.pem"
	)))
	.unwrap();
	let key = PrivateKeyDer::from_pem_slice(include_bytes!(concat!(
		env!("CARGO_MANIFEST_DIR"),
		"/../../../../test/net/fixtures/tls_server.key"
	)))
	.unwrap();
	let config = rustls::ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
		.with_safe_default_protocol_versions()
		.unwrap()
		.with_no_client_auth()
		.with_single_cert(vec![cert], key)
		.unwrap();
	TlsAcceptor::from(Arc::new(config))
}

async fn line<S: AsyncRead + Unpin>(socket: &mut BufReader<S>) -> String {
	let mut line = String::new();
	assert!(socket.read_line(&mut line).await.unwrap() > 0);
	line
}

async fn authentication(role: Role, accepted: bool) {
	let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
	let endpoint = Endpoint::new("localhost", listener.local_addr().unwrap().port(), true).unwrap();
	let (connection, worker, mut events) = Connection::open(
		endpoint,
		Some(trust(true)),
		role,
		"alice",
		"test identity",
		Some(SaslPlain {
			account: "acct".into(),
			password: "pw".into(),
		}),
		Duration::from_secs(60),
	)
	.unwrap();
	let task = tokio::task::spawn_local(worker.run());
	let (socket, _) = listener.accept().await.unwrap();
	let mut server = BufReader::new(acceptor().accept(socket).await.unwrap());
	assert_eq!(line(&mut server).await, "CAP LS 302\r\n");
	assert_eq!(line(&mut server).await, "NICK alice\r\n");
	assert!(line(&mut server).await.starts_with("USER alice "));
	server
		.get_mut()
		.write_all(b":s CAP * LS :sasl=PLAIN\r\n")
		.await
		.unwrap();
	assert_eq!(line(&mut server).await, "CAP REQ sasl\r\n");
	server.get_mut().write_all(b":s CAP * ACK :sasl\r\n").await.unwrap();
	assert_eq!(line(&mut server).await, "AUTHENTICATE PLAIN\r\n");
	server.get_mut().write_all(b"AUTHENTICATE +\r\n").await.unwrap();
	assert_eq!(line(&mut server).await, "AUTHENTICATE AGFjY3QAcHc=\r\n");
	if !accepted {
		server
			.get_mut()
			.write_all(b":s 904 alice :private server detail\r\n")
			.await
			.unwrap();
		let error = connection.finished().await.unwrap_err();
		assert!(error.contains("SASL"));
		assert!(!error.contains("private server detail"));
		assert!(!connection.registered());
		assert!(task.await.unwrap().is_err());
		assert!(events.next().await.is_none());
		return;
	}
	server.get_mut().write_all(b":s 903 alice :ok\r\n").await.unwrap();
	assert_eq!(line(&mut server).await, "CAP END\r\n");
	assert!(!connection.registered());
	server.get_mut().write_all(b":s 001 alice :welcome\r\n").await.unwrap();
	assert!(matches!(events.next().await, Some(Event::Registered { nick }) if nick == "alice"));
	connection
		.write(encode("JOIN", &["#a"]).unwrap())
		.unwrap()
		.wait()
		.await
		.unwrap();
	assert_eq!(line(&mut server).await, "JOIN #a\r\n");
	let queued = connection.write(encode("JOIN", &["#b"]).unwrap()).unwrap();
	server.get_mut().write_all(b"PING :priority\r\n").await.unwrap();
	assert_eq!(line(&mut server).await, "PONG priority\r\n");
	connection.close().await.unwrap();
	task.await.unwrap().unwrap();
	assert_eq!(
		queued.wait().await.unwrap_err().delivery,
		crate::irc::Delivery::NotWritten
	);
	let mut byte = [0];
	// A dropped TLS socket may close without close_notify; both outcomes
	// establish physical retirement, while a successful read would not.
	assert!(!matches!(server.read(&mut byte).await, Ok(n) if n > 0));
}

#[tokio::test]
async fn tls_sasl_feed_and_member_success_refusal_and_pacing() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(5), async {
				for role in [Role::Feed, Role::Member] {
					authentication(role, true).await;
					authentication(role, false).await;
				}
			})
			.await
			.expect("TLS/SASL scenario deadline");
		})
		.await;
}

#[tokio::test]
async fn certificate_trust_and_hostname_refuse_before_irc_registration() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(5), async {
				for (host, trusted) in [("localhost", false), ("127.0.0.1", true)] {
					let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
					let endpoint = Endpoint::new(host, listener.local_addr().unwrap().port(), true).unwrap();
					let (connection, worker, mut events) = Connection::open(
						endpoint,
						Some(trust(trusted)),
						Role::Member,
						"alice",
						"test identity",
						None,
						Duration::ZERO,
					)
					.unwrap();
					let task = tokio::task::spawn_local(worker.run());
					let (socket, _) = listener.accept().await.unwrap();
					assert!(acceptor().accept(socket).await.is_err());
					assert!(
						connection
							.finished()
							.await
							.unwrap_err()
							.contains("TLS handshake failed")
					);
					assert!(!connection.registered());
					assert!(task.await.unwrap().is_err());
					assert!(events.next().await.is_none());
				}
			})
			.await
			.expect("certificate refusal deadline");
		})
		.await;
}

#[tokio::test]
async fn cancellation_retires_a_stalled_tls_handshake() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(5), async {
				let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
				let endpoint = Endpoint::new("localhost", listener.local_addr().unwrap().port(), true).unwrap();
				let (connection, worker, _events) = Connection::open(
					endpoint,
					Some(trust(true)),
					Role::Feed,
					"feed",
					"bridge bot; admin: alice",
					None,
					Duration::ZERO,
				)
				.unwrap();
				let task = tokio::task::spawn_local(worker.run());
				let (mut socket, _) = listener.accept().await.unwrap();
				let mut bytes = [0; 4096];
				assert!(socket.read(&mut bytes).await.unwrap() > 0, "TLS handshake started");
				connection.close().await.unwrap();
				task.await.unwrap().unwrap();
				while socket.read(&mut bytes).await.unwrap() != 0 {}
				assert!(!connection.registered());
			})
			.await
			.expect("TLS cancellation deadline");
		})
		.await;
}
