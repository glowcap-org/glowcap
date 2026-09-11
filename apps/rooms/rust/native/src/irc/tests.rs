use super::*;
mod feed;
mod member;
use rooms_application::server::irc::{protocol::encode, registration::Role};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

#[tokio::test]
async fn registration_ping_delivery_and_close_use_the_native_socket_owner() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
			let endpoint = Endpoint::new("127.0.0.1", listener.local_addr().unwrap().port(), false).unwrap();
			let (connection, worker, mut events) =
				Connection::open(endpoint, None, Role::Feed, "feed", None, Duration::ZERO).unwrap();
			let task = tokio::task::spawn_local(worker.run());
			let (socket, _) = listener.accept().await.unwrap();
			let mut server = BufReader::new(socket);
			let mut line = String::new();
			server.read_line(&mut line).await.unwrap();
			assert_eq!(line, "NICK feed\r\n");
			line.clear();
			server.read_line(&mut line).await.unwrap();
			assert_eq!(line, "USER feed 0 * :glowcap rooms bridge\r\n");
			server
				.get_mut()
				.write_all(b"PING :before\r\n:server 001 feed :welcome\r\n")
				.await
				.unwrap();
			line.clear();
			server.read_line(&mut line).await.unwrap();
			assert_eq!(line, "PONG before\r\n");
			assert!(matches!(events.next().await, Some(Event::Registered { nick }) if nick == "feed"));
			connection
				.write(encode("PRIVMSG", &["#a", "hello"]).unwrap())
				.unwrap()
				.wait()
				.await
				.unwrap();
			line.clear();
			server.read_line(&mut line).await.unwrap();
			assert_eq!(line, "PRIVMSG #a hello\r\n");
			server
				.get_mut()
				.write_all(b":alice!u@host PRIVMSG #a :reply\r\n")
				.await
				.unwrap();
			assert!(matches!(events.next().await, Some(Event::Message(message)) if message.param(1) == Some("reply")));
			connection.close().await.unwrap();
			task.await.unwrap().unwrap();
			assert!(!connection.registered());
			line.clear();
			assert_eq!(server.read_line(&mut line).await.unwrap(), 0);
		})
		.await;
}

#[tokio::test(start_paused = true)]
async fn control_lines_bypass_pacing_and_cancellation_distinguishes_queued_writes() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let (writer, pump) = socket::Writer::open(Duration::from_secs(60));
			let (socket, mut peer) = tokio::io::duplex(1024);
			let task = tokio::task::spawn_local(pump.run(socket));
			writer
				.enqueue(encode("JOIN", &["#a"]).unwrap(), false)
				.unwrap()
				.wait()
				.await
				.unwrap();
			let queued = writer.enqueue(encode("JOIN", &["#b"]).unwrap(), false).unwrap();
			writer
				.enqueue(encode("PONG", &["server"]).unwrap(), true)
				.unwrap()
				.wait()
				.await
				.unwrap();
			let expected = b"JOIN #a\r\nPONG server\r\n";
			let mut observed = vec![0; expected.len()];
			peer.read_exact(&mut observed).await.unwrap();
			assert_eq!(observed, expected);
			task.abort();
			assert!(task.await.unwrap_err().is_cancelled());
			assert_eq!(queued.wait().await.unwrap_err().delivery, Delivery::NotWritten);
			assert!(writer.enqueue(encode("JOIN", &["#c"]).unwrap(), false).is_err());
		})
		.await;
}

#[tokio::test]
async fn a_partial_write_is_uncertain_and_admission_is_bounded() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let (writer, pump) = socket::Writer::open(Duration::ZERO);
			let (socket, mut peer) = tokio::io::duplex(1);
			let receipt = writer
				.enqueue(encode("PRIVMSG", &["#a", "body"]).unwrap(), false)
				.unwrap();
			let task = tokio::task::spawn_local(pump.run(socket));
			let mut first = [0];
			peer.read_exact(&mut first).await.unwrap();
			task.abort();
			assert!(task.await.unwrap_err().is_cancelled());
			assert_eq!(receipt.wait().await.unwrap_err().delivery, Delivery::Uncertain);

			let (writer, pump) = socket::Writer::open(Duration::ZERO);
			let mut admitted = Vec::new();
			for _ in 0..64 {
				admitted.push(writer.enqueue(encode("PING", &["x"]).unwrap(), false).unwrap());
			}
			assert_eq!(
				writer
					.enqueue(encode("PING", &["x"]).unwrap(), false)
					.err()
					.unwrap()
					.delivery,
				Delivery::NotWritten
			);
			drop(pump);
			for receipt in admitted {
				assert_eq!(receipt.wait().await.unwrap_err().delivery, Delivery::NotWritten);
			}
		})
		.await;
}
