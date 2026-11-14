//! The timeline proxy preserves messages and endpoint refusal codes. It does
//! not decode the capability query or convert text messages into byte frames.
use futures_util::{Sink, SinkExt, Stream, StreamExt};
use std::time::Duration;
use tokio::{
	io::{AsyncRead, AsyncWrite},
	sync::watch,
};
use tokio_tungstenite::{
	WebSocketStream,
	tungstenite::{
		Error, Message,
		protocol::{CloseFrame, frame::coding::CloseCode},
	},
};

pub(super) async fn run(
	mut near: super::upgrade::Socket,
	target: String,
	mut stop: watch::Receiver<bool>,
) -> Result<(), String> {
	let config = rooms_platform::websocket::config(rooms_application::server::trace::MAX_SOCKET_MESSAGE_BYTES);
	let connected = tokio::select! {
		_ = super::stopped(&mut stop) => return close(&mut near, None, false).await,
		result = tokio::time::timeout(Duration::from_secs(5), tokio_tungstenite::connect_async_with_config(
			target, Some(config), false)) => result
				.map_err(|_| "timeline dial timed out".to_owned()).and_then(|r| r.map_err(|_| "timeline endpoint is not reachable".to_owned())),
	};
	let (mut far, _) = match connected {
		Ok(connected) => connected,
		Err(error) => {
			let reason = Some(CloseFrame {
				code: CloseCode::Error,
				reason: "timeline endpoint is not reachable".into(),
			});
			return crate::cleanup::combine(Err(error), close(&mut near, reason, false).await);
		}
	};
	let (ended, near_ended, far_ended) = {
		let (near_write, near_read) = (&mut near).split();
		let (far_write, far_read) = (&mut far).split();
		tokio::select! {
			_ = super::stopped(&mut stop) => (Ok(None), false, false),
			ended = forward(near_read, far_write) => (ended, true, false),
			ended = forward(far_read, near_write) => (ended, false, true),
		}
	};
	let reason = match &ended {
		Ok(frame) => frame.clone(),
		Err(_) => Some(CloseFrame {
			code: CloseCode::Error,
			reason: "timeline socket failed".into(),
		}),
	};
	let oversized = match ended {
		Err(Failed::Oversized(largest)) => Some(largest),
		_ => None,
	};
	let (near_closed, far_closed) = tokio::join!(
		end(&mut near, reason.clone(), near_ended, oversized),
		end(&mut far, reason, far_ended, oversized)
	);
	let ended = ended.map(|_| ()).map_err(|failed| match failed {
		Failed::Oversized(_) => "timeline socket was sent a message past its bound".to_owned(),
		Failed::Other(reason) => reason.to_owned(),
	});
	crate::cleanup::combine(ended, crate::cleanup::combine(near_closed, far_closed))
}
/// Why a direction stopped with no close to carry across.
enum Failed {
	/// Its reader was sent a message past the socket's bound, which this is.
	Oversized(usize),
	Other(&'static str),
}
async fn forward<R, W>(mut read: R, mut write: W) -> Result<Option<CloseFrame>, Failed>
where
	R: Stream<Item = Result<Message, Error>> + Unpin,
	W: Sink<Message, Error = Error> + Unpin,
{
	const FAILED: Failed = Failed::Other("timeline socket failed");
	while let Some(message) = read.next().await {
		let message =
			message.map_err(|error| rooms_platform::websocket::oversized(&error).map_or(FAILED, Failed::Oversized))?;
		match message {
			message @ (Message::Binary(_) | Message::Text(_)) => {
				tokio::time::timeout(Duration::from_secs(10), write.send(message))
					.await
					.map_err(|_| Failed::Other("timeline socket stopped draining"))?
					.map_err(|_| FAILED)?;
			}
			Message::Close(frame) => {
				return Ok(frame.filter(|frame| {
					let code = u16::from(frame.code);
					code == 1000 || (3000..5000).contains(&code)
				}));
			}
			_ => {}
		}
	}
	Ok(None)
}
/// Close one side of the proxy. The side whose reader was sent a message
/// past its bound is told so, and every other side takes `reason`.
async fn end<S: AsyncRead + AsyncWrite + Unpin>(
	socket: &mut WebSocketStream<S>,
	reason: Option<CloseFrame>,
	read_ended: bool,
	oversized: Option<usize>,
) -> Result<(), String> {
	if let Some(largest) = oversized.filter(|_| read_ended) {
		rooms_platform::websocket::close_oversized(socket, largest, Duration::from_secs(3)).await;
		return Ok(());
	}
	close(socket, reason, read_ended).await
}
async fn close<S: AsyncRead + AsyncWrite + Unpin>(
	socket: &mut WebSocketStream<S>,
	reason: Option<CloseFrame>,
	received: bool,
) -> Result<(), String> {
	let closed = match tokio::time::timeout(Duration::from_secs(3), async {
		if received {
			socket.flush().await
		} else {
			socket.close(reason).await
		}
	})
	.await
	{
		Ok(Ok(())) | Ok(Err(Error::ConnectionClosed | Error::AlreadyClosed)) => Ok(()),
		Ok(Err(_)) => Err("timeline socket close failed".into()),
		Err(_) => Err("timeline socket close timed out".into()),
	};
	if closed.is_ok() && !received {
		// The peer may still be writing when this side closes, as a publisher
		// presenting its capability on open does. Read to its Close reply:
		// ending with those bytes unread makes the kernel answer with a reset,
		// which discards the close frame and its code before the peer reads it.
		// tolerant: a peer that never replies within the bound only delays this
		// socket's end; the close frame was already sent.
		let _ = tokio::time::timeout(Duration::from_secs(3), async {
			while let Some(Ok(_)) = socket.next().await {}
		})
		.await;
	}
	closed
}
