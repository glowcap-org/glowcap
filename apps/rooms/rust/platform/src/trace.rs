//! Process WebSocket effects for the shared managed trace publisher.
use crate::HostPlatform;
use futures_util::{SinkExt, StreamExt};
use rooms_runtime::{
	Error,
	trace::{Input, Socket, Transport},
};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, tungstenite::Message};

pub struct Connection {
	socket: WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>,
	closing: bool,
}
impl Transport for HostPlatform {
	type Socket = Connection;
	async fn connect(&self, target: &str) -> Result<Connection, Error> {
		let tls = if target.starts_with("wss://") {
			Some(tokio_tungstenite::Connector::Rustls(std::sync::Arc::new(
				crate::tls::system_config().await.map_err(Error::storage_message)?,
			)))
		} else {
			None
		};
		let config = tokio_tungstenite::tungstenite::protocol::WebSocketConfig::default()
			.max_message_size(Some(1024))
			.max_frame_size(Some(1024));
		let (socket, _) = tokio_tungstenite::connect_async_tls_with_config(target, Some(config), false, tls)
			.await
			.map_err(|error| Error::storage_message(error.to_string()))?;
		Ok(Connection { socket, closing: false })
	}
	async fn sleep(&self, milliseconds: u64) {
		tokio::time::sleep(std::time::Duration::from_millis(milliseconds)).await;
	}
}
impl Socket for Connection {
	async fn ready(&mut self) -> Result<(), Error> {
		Ok(())
	}
	async fn next(&mut self) -> Result<Input, Error> {
		match self.socket.next().await {
			Some(Ok(Message::Text(text))) => {
				if text.len() <= 1024 {
					Ok(Input::Text(text.to_string()))
				} else {
					Err(Error::exhausted("trace control exceeds its text budget"))
				}
			}
			Some(Ok(Message::Close(frame))) => {
				self.closing = true;
				Ok(frame.map_or(
					Input::Closed {
						code: 1000,
						reason: String::new(),
					},
					|frame| Input::Closed {
						code: frame.code.into(),
						reason: frame.reason.to_string(),
					},
				))
			}
			Some(Ok(_)) => Ok(Input::Other),
			Some(Err(error)) => Err(Error::closed(error.to_string())),
			None => Ok(Input::Closed {
				code: 1000,
				reason: String::new(),
			}),
		}
	}
	async fn send(&mut self, text: String) -> Result<(), Error> {
		self.socket
			.send(Message::Text(text.into()))
			.await
			.map_err(|error| Error::storage_message(error.to_string()))
	}
	async fn close(&mut self) -> Result<(), Error> {
		// A received close already queued its reply. Flush that reply instead
		// of sending another close frame into a connection that cannot write.
		let sent = if self.closing {
			self.socket.flush().await
		} else {
			self.socket.close(None).await
		};
		self.closing = true;
		match sent {
			Ok(()) => {}
			Err(
				tokio_tungstenite::tungstenite::Error::ConnectionClosed
				| tokio_tungstenite::tungstenite::Error::AlreadyClosed,
			) => return Ok(()),
			Err(error) => return Err(Error::storage_message(error.to_string())),
		}
		while let Some(result) = self.socket.next().await {
			match result {
				Ok(_) => {}
				Err(
					tokio_tungstenite::tungstenite::Error::ConnectionClosed
					| tokio_tungstenite::tungstenite::Error::AlreadyClosed,
				) => break,
				Err(error) => return Err(Error::storage_message(error.to_string())),
			}
		}
		Ok(())
	}
}
