//! HTTP bootstrap contracts, including a gateway login larger than the locator
//! limit. Peers keep sockets open to prove refusal is immediate.
use super::*;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

async fn respond<S: AsyncRead + AsyncWrite + Unpin>(mut socket: S, response: String) {
	let mut request = Vec::new();
	while !request.ends_with(b"\r\n\r\n") {
		request.push(socket.read_u8().await.unwrap());
		assert!(request.len() < 8192);
	}
	let _ = socket.write_all(response.as_bytes()).await;
	std::future::pending::<()>().await;
}

async fn response(
	status: &str,
	headers: &str,
	body: &str,
) -> Result<(hyper::StatusCode, Option<String>, Bytes), Failure> {
	let (client, server) = tokio::io::duplex(1024);
	let bytes = format!(
		"HTTP/1.1 {status}\r\nContent-Length: {}\r\n{headers}\r\n{body}",
		body.len()
	);
	let task = tokio::spawn(respond(server, bytes));
	let result = tokio::time::timeout(
		Duration::from_secs(2),
		exchange(client, &url::Url::parse("http://localhost/locator").unwrap()),
	)
	.await;
	task.abort();
	let _ = task.await;
	result.expect("bootstrap waited for an unused response body or socket close")
}

#[tokio::test]
async fn accepts_plain_locator_and_keeps_the_body_bound() {
	let (_, _, body) = response("200 OK", "Content-Type: text/plain\r\n", "ocapn://fixture\n")
		.await
		.unwrap();
	assert_eq!(body, "ocapn://fixture\n");
	let at_limit = "x".repeat(MAX_LOCATOR_BYTES);
	assert_eq!(
		response("200 OK", "", &at_limit).await.unwrap().2.len(),
		MAX_LOCATOR_BYTES
	);
	let error = response("200 OK", "", &(at_limit + "x")).await.unwrap_err();
	assert_eq!(error.class, "bootstrap");
	assert!(error.message.contains("4096-byte locator limit"));
}

#[tokio::test]
async fn html_login_is_not_a_length_error() {
	for mime in ["text/html; charset=utf-8", "Text/HTML", "application/xhtml+xml"] {
		let error = response(
			"200 OK",
			&format!("Content-Type: {mime}\r\n"),
			&"private login content".repeat(2000),
		)
		.await
		.unwrap_err();
		assert_eq!(error.class, "bootstrap");
		assert!(error.message.contains("HTML") && error.message.contains("browser login"));
		assert!(!error.message.contains("private login content"));
	}
}

#[tokio::test]
async fn http_errors_and_redirects_do_not_collect_bodies() {
	for status in ["401 Unauthorized", "403 Forbidden", "503 Service Unavailable"] {
		let error = response(status, "Content-Type: text/html\r\n", &"x".repeat(40_000))
			.await
			.unwrap_err();
		assert_eq!(error.class, "http");
		assert!(error.message.contains(status));
	}
	let (status, location, body) = response(
		"302 Found",
		"Location: /next\r\nContent-Type: text/html\r\n",
		&"x".repeat(40_000),
	)
	.await
	.unwrap();
	assert!(status.is_redirection());
	assert_eq!(location.as_deref(), Some("/next"));
	assert!(body.is_empty());
}

#[tokio::test]
async fn redirected_login_reports_origin_without_tokens() {
	let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
	let origin = format!("http://{}", listener.local_addr().unwrap());
	let url = format!("{origin}/locator?private-token=hidden");
	let server = tokio::spawn(async move {
		let mut connections = tokio::task::JoinSet::new();
		for response in [
			"HTTP/1.1 302 Found\r\nLocation: /login?private-token=hidden\r\nContent-Length: 0\r\n\r\n".into(),
			format!(
				"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 40000\r\n\r\n{}",
				"x".repeat(40_000)
			),
		] {
			let (socket, _) = listener.accept().await.unwrap();
			connections.spawn(respond(socket, response));
		}
		std::future::pending::<()>().await;
	});
	let result = tokio::time::timeout(Duration::from_secs(2), resolve(&url)).await;
	server.abort();
	let _ = server.await;
	let error = result.unwrap().unwrap_err();
	assert_eq!(error.class, "bootstrap");
	assert!(error.message.contains(&origin) && error.message.contains("HTML"));
	assert!(!error.message.contains("private-token") && !error.message.contains("hidden"));
}

#[tokio::test]
async fn direct_locator_needs_no_http() {
	assert_eq!(resolve("ocapn://fixture").await.unwrap(), "ocapn://fixture");
}
