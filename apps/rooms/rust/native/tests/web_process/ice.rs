//! The public /ice path crosses a real TLS issuer; bearer custody stays native.
use super::*;
use std::sync::Arc;
use tokio::net::TcpListener;
use tokio_rustls::{
	rustls::{
		self,
		pki_types::{pem::PemObject, CertificateDer, PrivateKeyDer},
	},
	TlsAcceptor,
};

struct Issuer {
	listener: TcpListener,
	tls: TlsAcceptor,
}
impl Issuer {
	async fn new() -> Self {
		let fixtures = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../../test/net/fixtures");
		let config = rustls::ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
			.with_safe_default_protocol_versions()
			.unwrap()
			.with_no_client_auth()
			.with_single_cert(
				vec![CertificateDer::from_pem_file(fixtures.join("tls_server.pem")).unwrap()],
				PrivateKeyDer::from_pem_file(fixtures.join("tls_server.key")).unwrap(),
			)
			.unwrap();
		Self {
			listener: TcpListener::bind(("127.0.0.1", 0)).await.unwrap(),
			tls: TlsAcceptor::from(Arc::new(config)),
		}
	}
	fn command(&self, hostname: &str) -> Command {
		let mut command = Web::command(0);
		let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../../test/net/fixtures/tls_root.pem");
		command
			.env("SSL_CERT_FILE", root)
			.env("SSL_CERT_DIR", "")
			.env("GLOWCAP_ROOMS_ICE_SERVERS", "stun:deployment.example")
			.env(
				"GLOWCAP_ROOMS_TURN_CREDENTIALS_URL",
				format!(
					"https://{hostname}:{}/credentials?region=test",
					self.listener.local_addr().unwrap().port()
				),
			)
			.env("GLOWCAP_ROOMS_TURN_BEARER_TOKEN", "private-issuer-bearer")
			.env("GLOWCAP_ROOMS_TURN_TTL_SECONDS", "600");
		command
	}
	async fn answer(&self, status: u16, body: &str, declared: usize) {
		let (socket, _) = self.listener.accept().await.unwrap();
		let mut socket = self.tls.accept(socket).await.unwrap();
		let mut request = Vec::new();
		loop {
			let byte = socket.read_u8().await.unwrap();
			request.push(byte);
			assert!(request.len() <= 4096);
			if request.ends_with(b"\r\n\r\n") {
				break;
			}
		}
		let headers = String::from_utf8(request).unwrap();
		assert!(
			headers.starts_with("POST /credentials?region=test HTTP/1.1\r\n"),
			"{headers}"
		);
		assert!(headers.contains("authorization: Bearer private-issuer-bearer\r\n"));
		let length: usize = headers
			.lines()
			.find_map(|l| l.strip_prefix("content-length: "))
			.unwrap()
			.parse()
			.unwrap();
		assert!(length < 128);
		let mut payload = vec![0; length];
		socket.read_exact(&mut payload).await.unwrap();
		assert_eq!(
			serde_json::from_slice::<serde_json::Value>(&payload).unwrap(),
			serde_json::json!({"ttl":600})
		);
		socket
			.write_all(
				format!("HTTP/1.1 {status} Test\r\nContent-Length: {declared}\r\nConnection: close\r\n\r\n{body}")
					.as_bytes(),
			)
			.await
			.unwrap();
		// A refused body may close the channel before its response is flushed.
		let _ = socket.shutdown().await;
	}
}

#[tokio::test(flavor = "current_thread")]
async fn web_issues_turn_over_tls_without_publishing_bearer_or_refusal_bodies() {
	tokio::time::timeout(Duration::from_secs(25), async {
		let issuer = Issuer::new().await;
		let mut web = Web::spawn(issuer.command("localhost"));
		web.ready().await;
		let issued = r#"{"iceServers":[{"urls":"stun:issuer.example"},{"urls":["stun:ignored.example","turns:turn.example:5349"],"username":"temporary-user","credential":"temporary-password"}]}"#;
		let (reply, ()) = tokio::join!(web.get("/ice"), issuer.answer(200, issued, issued.len()));
		assert!(reply.starts_with("HTTP/1.1 200"), "{reply}");
		assert!(reply.contains("no-store"), "{reply}");
		assert!(!reply.contains("private-issuer-bearer"));
		let body: serde_json::Value = serde_json::from_str(reply.split_once("\r\n\r\n").unwrap().1).unwrap();
		assert_eq!(body, serde_json::json!([
			{"urls":"stun:deployment.example"},
			{"urls":["turns:turn.example:5349"],"username":"temporary-user","credential":"temporary-password"}
		]));
		for (status, body, declared) in [
			(403, "private-issuer-bearer", 21),
			(200, "", 65537),
			(200, "bad JSON", 8),
			(200, r#"{"iceServers":[{"urls":"stun:only.example"}]}"#, 46),
		] {
			let declared = if declared == 65537 { declared } else { body.len() };
			let (reply, ()) = tokio::join!(web.get("/ice"), issuer.answer(status, body, declared));
			assert!(reply.starts_with("HTTP/1.1 503"), "{reply}");
			assert!(!reply.contains("private-issuer-bearer"), "issuer body or bearer escaped");
			assert!(!reply.contains("stun:deployment.example"), "issuer refusal silently substituted STUN");
		}
		web.stop().await;
	}).await.expect("native TURN issuer scenario deadline");
}

#[tokio::test(flavor = "current_thread")]
async fn web_refuses_a_turn_issuer_with_the_wrong_tls_identity() {
	tokio::time::timeout(Duration::from_secs(25), async {
		let issuer = Issuer::new().await;
		let mut web = Web::spawn(issuer.command("127.0.0.1"));
		web.ready().await;
		let handshake = async {
			let (socket, _) = issuer.listener.accept().await.unwrap();
			assert!(issuer.tls.accept(socket).await.is_err(), "wrong DNS identity accepted");
		};
		let (reply, ()) = tokio::join!(web.get("/ice"), handshake);
		assert!(reply.starts_with("HTTP/1.1 503"), "{reply}");
		assert!(!reply.contains("private-issuer-bearer"));
		web.stop().await;
	})
	.await
	.expect("TURN TLS refusal scenario deadline");
}
