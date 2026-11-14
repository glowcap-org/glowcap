use super::*;
use futures_util::{SinkExt, StreamExt};
use tokio::io::AsyncWriteExt;
use tokio_tungstenite::tungstenite::protocol::{CloseFrame, Role, frame::coding::CloseCode};

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
async fn a_write_larger_than_one_message_goes_out_as_several() {
	let cap = glowcap::BINDING_WEBSOCKET_MESSAGE_CAP_BYTES;
	let (a, b) = tokio::io::duplex(64 * 1024);
	let mut channel = WsBytes::new(WebSocketStream::from_raw_socket(a, Role::Server, None).await);
	let mut peer = WebSocketStream::from_raw_socket(b, Role::Client, None).await;
	let bytes = vec![7; cap + 1];
	let wrote = async {
		channel.write_all(&bytes).await.unwrap();
		channel.flush().await.unwrap();
	};
	let read = async {
		let mut lengths = Vec::new();
		while lengths.iter().sum::<usize>() < cap + 1 {
			let Message::Binary(message) = peer.next().await.unwrap().unwrap() else {
				panic!("the peer received something other than stream bytes")
			};
			lengths.push(message.len());
		}
		lengths
	};
	let ((), lengths) = tokio::join!(wrote, read);
	assert_eq!(lengths, [cap, 1]);
}

#[tokio::test]
async fn a_bounded_socket_reads_a_message_at_its_bound_and_closes_one_past_it_by_its_size() {
	let bound = 64 * 1024;
	// The connection holds far less than the message, so the peer finishes
	// writing it only if the bounded socket keeps taking bytes off.
	let (a, b) = tokio::io::duplex(1024);
	let mut bounded = WebSocketStream::from_raw_socket(a, Role::Server, Some(config(bound))).await;
	let mut peer = WebSocketStream::from_raw_socket(b, Role::Client, None).await;
	let sent = async {
		peer.send(Message::Binary(vec![7; bound].into())).await.unwrap();
		peer.send(Message::Binary(vec![7; bound + 1].into())).await.unwrap();
		let Some(Ok(Message::Close(Some(close)))) = peer.next().await else {
			panic!("the peer was not told why it was closed");
		};
		assert_eq!(close.code, CloseCode::Size);
		assert!(close.reason.contains(&bound.to_string()));
	};
	let read = async move {
		assert_eq!(bounded.next().await.unwrap().unwrap().len(), bound);
		let refused = bounded.next().await.unwrap().unwrap_err();
		assert_eq!(
			oversized(&refused),
			Some(bound),
			"the bounded socket failed another way: {refused}"
		);
		close_oversized(&mut bounded, bound, Duration::from_secs(5)).await;
	};
	tokio::join!(sent, read);
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
