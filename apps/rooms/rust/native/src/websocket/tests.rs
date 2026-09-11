use super::*;
use futures_util::{SinkExt, StreamExt};
use tokio::io::AsyncWriteExt;
use tokio_tungstenite::tungstenite::protocol::{frame::coding::CloseCode, CloseFrame, Role};

// Sink::poll_close alone returned Ready before the peer even read our Close.
// Both roles must retain their channel through the reciprocal handshake.
#[tokio::test]
async fn shutdown_waits_for_the_peer_close_and_survives_observer_cancellation() {
	for role in [Role::Server, Role::Client] {
		let (a, b) = tokio::io::duplex(1024);
		let peer_role = if role == Role::Server {
			Role::Client
		} else {
			Role::Server
		};
		let mut channel = WsBytes::new(WebSocketStream::from_raw_socket(a, role, None).await);
		let mut peer = WebSocketStream::from_raw_socket(b, peer_role, None).await;
		{
			let closing = channel.shutdown();
			tokio::pin!(closing);
			std::future::poll_fn(|cx| {
				assert!(closing.as_mut().poll(cx).is_pending());
				Poll::Ready(())
			})
			.await;
		}
		assert!(matches!(peer.next().await.unwrap().unwrap(), Message::Close(_)));
		peer.flush().await.unwrap();
		channel.shutdown().await.unwrap();
		channel.shutdown().await.unwrap();
	}
}

#[tokio::test]
async fn explicit_close_intent_survives_observer_cancellation() {
	let (a, b) = tokio::io::duplex(1024);
	let mut channel = WsBytes::new(WebSocketStream::from_raw_socket(a, Role::Server, None).await);
	let mut peer = WebSocketStream::from_raw_socket(b, Role::Client, None).await;
	{
		let closing = channel.close(Some(CloseFrame {
			code: CloseCode::Away,
			reason: "session moved".into(),
		}));
		tokio::pin!(closing);
		std::future::poll_fn(|cx| {
			assert!(closing.as_mut().poll(cx).is_pending());
			Poll::Ready(())
		})
		.await;
	}
	let Message::Close(Some(frame)) = peer.next().await.unwrap().unwrap() else {
		panic!("peer did not receive the explicit close intent")
	};
	assert_eq!(frame.code, CloseCode::Away);
	assert_eq!(frame.reason, "session moved");
	peer.flush().await.unwrap();
	channel.shutdown().await.unwrap();
}

#[tokio::test]
async fn channel_retirement_owns_the_websocket_close_handshake() {
	let (a, b) = tokio::io::duplex(1024);
	let socket = WebSocketStream::from_raw_socket(a, Role::Server, None).await;
	let mut peer = WebSocketStream::from_raw_socket(b, Role::Client, None).await;
	let channel = WsBytes::new(socket).into_channel();
	let closing = channel.close();
	tokio::pin!(closing);
	std::future::poll_fn(|cx| {
		assert!(closing.as_mut().poll(cx).is_pending());
		Poll::Ready(())
	})
	.await;

	assert!(matches!(peer.next().await.unwrap().unwrap(), Message::Close(_)));
	peer.flush().await.unwrap();
	closing.await.unwrap();
}
