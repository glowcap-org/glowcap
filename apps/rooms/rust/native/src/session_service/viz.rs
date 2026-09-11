//! Native websocket effects for the shared session visualization publisher.
use futures_util::{SinkExt, StreamExt};
use rooms_runtime::session_service::viz::{Input, Socket, Transport};
use tokio_tungstenite::{tungstenite::Message, MaybeTlsStream, WebSocketStream};
#[derive(Clone)]
pub struct Native;
pub type Viz = rooms_runtime::session_service::viz::Viz<Native>;
pub struct Connection(WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>);
impl rooms_glowcap::client::Deadline for Native {
	async fn within<T>(&self, milliseconds: u64, work: impl std::future::Future<Output = T>) -> Option<T> {
		tokio::time::timeout(std::time::Duration::from_millis(milliseconds), work)
			.await
			.ok()
	}
}
impl Transport for Native {
	type Socket = Connection;
	async fn connect(&self, target: &str) -> Result<Connection, String> {
		tokio_tungstenite::connect_async(target)
			.await
			.map(|(socket, _)| Connection(socket))
			.map_err(|e| e.to_string())
	}
	async fn sleep(&self, milliseconds: u64) {
		tokio::time::sleep(std::time::Duration::from_millis(milliseconds)).await;
	}
}
impl Socket for Connection {
	async fn next(&mut self) -> Result<Input, String> {
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
			Some(Err(error)) => Err(error.to_string()),
			None => Err("visualization socket closed".into()),
		}
	}
	async fn send(&mut self, text: String) -> Result<(), String> {
		self.0.send(Message::text(text)).await.map_err(|e| e.to_string())
	}
	async fn close(&mut self) -> Result<(), String> {
		use tokio_tungstenite::tungstenite::Error;
		match self.0.close(None).await {
			Ok(()) => {}
			Err(
				Error::ConnectionClosed
				| Error::AlreadyClosed
				| Error::Protocol(tokio_tungstenite::tungstenite::error::ProtocolError::SendAfterClosing),
			) => return Ok(()),
			Err(error) => return Err(error.to_string()),
		}
		// The shared publisher bounds this wait. Sending a close frame alone
		// does not establish that the peer has finished the closing handshake.
		while let Some(message) = self.0.next().await {
			match message {
				Ok(Message::Close(_)) | Err(Error::ConnectionClosed | Error::AlreadyClosed) => break,
				Err(error) => return Err(error.to_string()),
				Ok(_) => {}
			}
		}
		Ok(())
	}
}
