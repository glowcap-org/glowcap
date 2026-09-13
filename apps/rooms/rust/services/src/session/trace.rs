//! Host WebSocket effects for the shared session visualization publisher.
use futures_util::{SinkExt, StreamExt};
use rooms_runtime::Error as Classed;
use rooms_runtime::service::trace::{Input, Socket, Transport};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, tungstenite::Message};
#[derive(Clone)]
pub struct HostTraceTransport;
pub type Trace = rooms_runtime::service::trace::Trace<HostTraceTransport>;
pub struct Connection(WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>);
impl rooms_glowcap::client::Deadline for HostTraceTransport {
	async fn within<T>(&self, milliseconds: u64, work: impl std::future::Future<Output = T>) -> Option<T> {
		tokio::time::timeout(std::time::Duration::from_millis(milliseconds), work)
			.await
			.ok()
	}
}
impl Transport for HostTraceTransport {
	type Socket = Connection;
	async fn connect(&self, target: &str) -> Result<Connection, Classed> {
		tokio_tungstenite::connect_async(target)
			.await
			.map(|(socket, _)| Connection(socket))
			.map_err(socket_failure)
	}
	async fn sleep(&self, milliseconds: u64) {
		tokio::time::sleep(std::time::Duration::from_millis(milliseconds)).await;
	}
}
impl Socket for Connection {
	async fn next(&mut self) -> Result<Input, Classed> {
		match self.0.next().await {
			Some(Ok(Message::Text(text))) => Ok(Input::Text(text.to_string())),
			Some(Ok(Message::Close(frame))) => Ok(match frame {
				Some(frame) => Input::Closed {
					code: frame.code.into(),
					reason: frame.reason.to_string(),
				},
				None => Input::Closed {
					code: 1000,
					reason: String::new(),
				},
			}),
			Some(Ok(_)) => Ok(Input::Other),
			Some(Err(error)) => Err(socket_failure(error)),
			None => Err(Classed::closed("visualization socket closed")),
		}
	}
	async fn send(&mut self, text: String) -> Result<(), Classed> {
		self.0.send(Message::text(text)).await.map_err(socket_failure)
	}
	async fn close(&mut self) -> Result<(), Classed> {
		use tokio_tungstenite::tungstenite::Error;
		match self.0.close(None).await {
			Ok(()) => {}
			Err(
				Error::ConnectionClosed
				| Error::AlreadyClosed
				| Error::Protocol(tokio_tungstenite::tungstenite::error::ProtocolError::SendAfterClosing),
			) => return Ok(()),
			Err(error) => return Err(socket_failure(error)),
		}
		// The shared publisher bounds this wait. Sending a close frame alone
		// does not establish that the peer has finished the closing handshake.
		while let Some(message) = self.0.next().await {
			match message {
				Ok(Message::Close(_)) | Err(Error::ConnectionClosed | Error::AlreadyClosed) => break,
				Err(error) => return Err(socket_failure(error)),
				Ok(_) => {}
			}
		}
		Ok(())
	}
}

/// This socket's own I/O giving way, told apart from the visualizer declining
/// anything: nothing was refused here, the connection simply failed.
fn socket_failure(error: tokio_tungstenite::tungstenite::Error) -> Classed {
	use tokio_tungstenite::tungstenite::Error;
	match error {
		Error::ConnectionClosed | Error::AlreadyClosed => Classed::closed(error.to_string()),
		error => Classed::storage_message(error.to_string()),
	}
}
