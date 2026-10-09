//! Own trace connection admission, transport routing and viewer retirement.
use super::super::super::notice::Notice;
use super::{Shared, Viewer};
use glowcap::{Host, Session};
use rooms_application::server::trace::{
	self, NOT_A_SOCKET, PRODUCER_LIMIT_CLOSE_CODE, PUBLISH_PATH, REFUSED_CLOSE_CODE, REFUSED_REASON,
	constant_time_equals, records::parse_record,
};
use rooms_platform::websocket::WsBytes;
use std::{cell::RefCell, rc::Rc, time::Duration};
use tokio::{
	net::{TcpListener, TcpStream},
	sync::Notify,
	task::JoinSet,
};
use tokio_tungstenite::tungstenite::{
	Message,
	handshake::server::{Request, Response},
	protocol::{CloseFrame, frame::coding::CloseCode},
};
const HANDSHAKE: Duration = Duration::from_secs(10);
const HEAD_DEADLINE: Duration = Duration::from_secs(5);

/// Accept sockets for as long as the endpoint stands. Every connection task
/// is owned here: a panic in one is reported, and aborting this task takes
/// them all with it.
pub(super) async fn accept(listener: TcpListener, feed: Shared, trace_host: Host, swiss: String, port: u16) {
	let mut connections = JoinSet::new();
	loop {
		tokio::select! {
			accepted = listener.accept(), if connections.len() < rooms_platform::serving::CONNECTION_LIMIT => match accepted {
				Ok((stream, _)) => {
					connections.spawn_local(connection(
						stream,
						feed.clone(),
						trace_host.clone(),
						swiss.clone(),
						port,
					));
				}
				Err(error) => {
					feed.borrow().report.clone()(Notice::Trouble {
						source: "the trace endpoint could not accept a socket".into(),
						reason: error.to_string(),
					});
					tokio::time::sleep(rooms_platform::serving::ACCEPT_RETRY).await;
				}
			},
			Some(ended) = connections.join_next(), if !connections.is_empty() => {
				if let Err(join) = ended {
					feed.borrow().report.clone()(Notice::Trouble {
						source: "a trace connection task failed".into(),
						reason: join.to_string(),
					});
				}
			}
		}
	}
}

/// What the upgrade request asked for: its path and query, read during the
/// handshake and answered after it.
#[derive(Clone, Default)]
struct Asked(Rc<RefCell<Option<Uri>>>);
/// A request's path and query.
type Uri = (String, Option<String>);

impl tokio_tungstenite::tungstenite::handshake::server::Callback for Asked {
	// The refusal type is the handshake crate's; nothing here refuses.
	#[allow(clippy::result_large_err)]
	fn on_request(
		self,
		request: &Request,
		response: Response,
	) -> Result<Response, tokio_tungstenite::tungstenite::handshake::server::ErrorResponse> {
		*self.0.borrow_mut() = Some((
			request.uri().path().to_owned(),
			request.uri().query().map(str::to_owned),
		));
		Ok(response)
	}
}

/// One socket: a plain request is told where the doors are; an upgrade is
/// admitted only with the capability, then serves as a producer or a viewer.
async fn connection(mut stream: TcpStream, feed: Shared, trace_host: Host, swiss: String, port: u16) {
	let (head, prefix) = match tokio::time::timeout(HEAD_DEADLINE, connection_head(&mut stream)).await {
		Ok(Ok(head)) => head,
		_ => return,
	};
	// Consumed admission bytes are replayed exactly once into either transport.
	// The bounded prefix retires after the handshake reads it.
	use tokio::io::AsyncReadExt;
	let (reader, writer) = stream.into_split();
	let stream = tokio::io::join(std::io::Cursor::new(prefix).chain(reader), writer);
	if head.is_none() {
		let designator = format!("127.0.0.1:{port}");
		match Session::accept_over(&trace_host, "tcp", &designator, &designator, stream, Some(HANDSHAKE)).await {
			Ok(session) => serve_viewer(session, feed).await,
			Err(cause) => feed.borrow().report.clone()(Notice::Trouble {
				source: "a trace capability could not open its session".into(),
				reason: cause.to_string(),
			}),
		}
		return;
	}
	if !head.expect("HTTP head").contains("upgrade: websocket") {
		let body = NOT_A_SOCKET;
		let response = format!(
			"HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
			body.len()
		);
		let mut stream = stream;
		use tokio::io::AsyncWriteExt;
		// tolerant: a refused plain request that cannot even be answered is
		// simply dropped.
		let _ = stream.write_all(response.as_bytes()).await;
		let _ = stream.shutdown().await;
		return;
	}
	let asked = Asked::default();
	let ws = tokio::time::timeout(HANDSHAKE, tokio_tungstenite::accept_hdr_async(stream, asked.clone())).await;
	let Ok(Ok(mut ws)) = ws else {
		return;
	};
	let (path, query) = asked.0.borrow().clone().unwrap_or_default();
	let presented = query
		.as_deref()
		.unwrap_or("")
		.split('&')
		.find_map(|pair| pair.strip_prefix("cap="))
		.unwrap_or("");
	use futures_util::{SinkExt, StreamExt};
	// The byte channel grants no trace access. Fetch still requires the Swiss.
	// The viewer and producer routes additionally admit their HTTP token.
	let channel = path == trace::CHANNEL_PATH && query.is_none();
	if !channel && (!matches!(path.as_str(), "/" | PUBLISH_PATH) || !constant_time_equals(presented, &swiss)) {
		// Refused with no handlers installed: nothing sent is parsed.
		let _ = ws
			.send(Message::Close(Some(CloseFrame {
				code: CloseCode::from(REFUSED_CLOSE_CODE),
				reason: REFUSED_REASON.into(),
			})))
			.await;
		return;
	}
	if path == PUBLISH_PATH {
		let scope = feed.borrow_mut().endpoint.admit_producer(true);
		let Some(scope) = scope else {
			let _ = ws
				.send(Message::Close(Some(CloseFrame {
					code: CloseCode::from(PRODUCER_LIMIT_CLOSE_CODE),
					reason: format!("rooms trace: producer limit {} reached", trace::MAX_REMOTE_PRODUCERS).into(),
				})))
				.await;
			return;
		};
		let ready = {
			let feed = feed.borrow();
			feed.endpoint.publish_ready_line(feed.now_ns())
		};
		if ws.send(Message::Text(ready.into())).await.is_err() {
			let mut feed = feed.borrow_mut();
			let now = feed.now_ns();
			for stamped in feed.endpoint.drop_producer(&scope, true, now) {
				feed.broadcast(&stamped.line);
			}
			return;
		}
		while let Some(Ok(message)) = ws.next().await {
			let Message::Text(text) = message else {
				continue;
			};
			let Some(rec) = parse_record(text.as_str()) else {
				continue;
			};
			{
				let mut feed = feed.borrow_mut();
				if !feed.admits_remote(&rec) {
					continue;
				}
				let now = feed.now_ns();
				for stamped in feed.endpoint.ingest(&scope, rec, now) {
					feed.broadcast(&stamped.line);
				}
			}
			// A producer's burst arrives already buffered on its socket, so
			// the socket never parks this loop; the drains get their turn
			// between records rather than after the whole burst.
			tokio::task::yield_now().await;
		}
		let mut feed = feed.borrow_mut();
		let now = feed.now_ns();
		for stamped in feed.endpoint.drop_producer(&scope, true, now) {
			feed.broadcast(&stamped.line);
		}
		return;
	}
	// A viewer: the socket is the byte channel of a CapTP session on the
	// trace host, where the trace object answers.
	let designator = format!("127.0.0.1:{port}");
	let session = match Session::accept_channel(
		&trace_host,
		glowcap::AcceptedTransport {
			transport: "tcp",
			designator: glowcap::ChannelDesignator::Address(&designator),
			local_address: &designator,
			verified_channel_key: None,
		},
		WsBytes::new(ws).into_channel(),
		Some(HANDSHAKE),
	)
	.await
	{
		Ok(session) => session,
		Err(cause) => {
			feed.borrow().report.clone()(Notice::Trouble {
				source: "a trace viewer could not open its session".into(),
				reason: cause.to_string(),
			});
			return;
		}
	};
	serve_viewer(session, feed).await;
}
/// One 4096-byte prefix belongs to connection admission until either handshake
/// consumes it. Fragmented input needs owned replay bytes because raw CapTP and
/// HTTP share this socket; peeking cannot wait for new bytes without polling.
/// The normalized HTTP text is separate bounded parse scratch and retires at
/// routing. Connection count and the caller's deadline bound aggregate custody.
async fn connection_head(
	stream: &mut (impl tokio::io::AsyncRead + Unpin),
) -> std::io::Result<(Option<String>, Vec<u8>)> {
	use tokio::io::AsyncReadExt;
	let mut head = vec![0u8; 4096];
	let mut size = 0;
	loop {
		let read = stream.read(&mut head[size..]).await?;
		if read == 0 {
			return Err(std::io::ErrorKind::UnexpectedEof.into());
		}
		size += read;
		let prefix = &head[..size.min(4)];
		if !b"GET ".starts_with(prefix) {
			head.truncate(size);
			return Ok((None, head));
		}
		if size >= 4 && head[..size].windows(4).any(|end| end == b"\r\n\r\n") {
			head.truncate(size);
			return Ok((Some(String::from_utf8_lossy(&head).to_ascii_lowercase()), head));
		}
		if size == head.len() {
			return Err(std::io::ErrorKind::InvalidData.into());
		}
	}
}

async fn serve_viewer(session: Session, feed: Shared) {
	// Retiring the viewer's subscription asks this task to close the
	// session, so a viewer that cannot keep up ends here, on its own turn.
	let retire = Rc::new(Notify::new());
	feed.borrow_mut().viewers.push(Viewer {
		session: session.borrowed(),
		retire: retire.clone(),
	});
	let served = tokio::select! {
		served = session.serve() => served,
		_ = retire.notified() => Ok(()),
	};
	{
		let mut feed = feed.borrow_mut();
		feed.remove_subscriber_of(&session);
		feed.viewers.retain(|viewer| !viewer.session.same_session(&session));
	}
	let closed = session.close(glowcap::PendingWork::Cancel).await;
	for outcome in [served, closed] {
		if let Err(cause) = outcome
			&& !rooms_platform::serving::left(&cause)
		{
			feed.borrow().report.clone()(Notice::Trouble {
				source: "a trace viewer session ended".into(),
				reason: cause.to_string(),
			});
		}
	}
}

#[cfg(test)]
mod tests {
	use super::connection_head;
	use tokio::io::AsyncWriteExt;

	#[tokio::test]
	async fn fragmented_http_waits_for_complete_head_and_preserves_trailing_bytes() {
		let (mut incoming, mut outgoing) = tokio::io::duplex(8192);
		outgoing.write_all(b"G").await.unwrap();
		let task = tokio::spawn(async move { connection_head(&mut incoming).await });
		tokio::task::yield_now().await;
		assert!(!task.is_finished());
		let rest = b"ET /publish HTTP/1.1\r\nUpgrade: websocket\r\n\r\ntrailing";
		outgoing.write_all(rest).await.unwrap();
		let (head, prefix) = task.await.unwrap().unwrap();
		assert!(head.unwrap().contains("upgrade: websocket"));
		assert_eq!(prefix, [b"G".as_slice(), rest].concat());
	}
	#[tokio::test]
	async fn raw_prefix_is_unchanged_and_oversized_http_is_refused() {
		let raw = b"\x83\x00\x34captp";
		let (head, prefix) = connection_head(&mut raw.as_slice()).await.unwrap();
		assert!(head.is_none());
		assert_eq!(prefix, raw);
		let mut oversized = vec![b'x'; 4096];
		oversized[..4].copy_from_slice(b"GET ");
		assert_eq!(
			connection_head(&mut oversized.as_slice()).await.unwrap_err().kind(),
			std::io::ErrorKind::InvalidData
		);
	}
}
