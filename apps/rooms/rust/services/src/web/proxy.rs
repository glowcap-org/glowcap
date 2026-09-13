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
	let connected = tokio::select! {
		_ = super::stopped(&mut stop) => return close(&mut near, None, false).await,
		result = tokio::time::timeout(Duration::from_secs(5), tokio_tungstenite::connect_async_with_config(
			target, Some(super::upgrade::config()), false)) => result
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
	let (near_closed, far_closed) = tokio::join!(
		close(&mut near, reason.clone(), near_ended),
		close(&mut far, reason, far_ended)
	);
	crate::cleanup::combine(ended.map(|_| ()), crate::cleanup::combine(near_closed, far_closed))
}
async fn forward<R, W>(mut read: R, mut write: W) -> Result<Option<CloseFrame>, String>
where
	R: Stream<Item = Result<Message, Error>> + Unpin,
	W: Sink<Message, Error = Error> + Unpin,
{
	while let Some(message) = read.next().await {
		match message.map_err(|_| "timeline socket failed")? {
			message @ (Message::Binary(_) | Message::Text(_)) => {
				tokio::time::timeout(Duration::from_secs(10), write.send(message))
					.await
					.map_err(|_| "timeline socket stopped draining")?
					.map_err(|_| "timeline socket failed")?;
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
async fn close<S: AsyncRead + AsyncWrite + Unpin>(
	socket: &mut WebSocketStream<S>,
	reason: Option<CloseFrame>,
	received: bool,
) -> Result<(), String> {
	match tokio::time::timeout(Duration::from_secs(3), async {
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
	}
}
