use super::*;
use rooms_application::{
	room::policy::MembershipKind,
	server::irc::{
		gateway::Gateway,
		model::{NetworkChoice, channel_key},
		wire::Notice,
	},
};
use std::{cell::RefCell, rc::Rc};

#[tokio::test]
async fn channels_share_one_feed_and_retire_without_ending_their_sibling() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(10), scenario())
				.await
				.expect("host IRC feed deadline");
		})
		.await;
}
async fn scenario() {
	let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
	let mut gateway = Gateway::<u32, u8>::default();
	gateway
		.open_network(NetworkChoice {
			network: "test".into(),
			host: "127.0.0.1".into(),
			port: listener.local_addr().unwrap().port(),
			tls: false,
			nick: "feed".into(),
			realname: "bridge bot; admin: alice".into(),
			sasl: None,
		})
		.unwrap();
	for (channel, id) in [("#a", "p1"), ("#b", "p2")] {
		gateway.join_bridge("test", channel, id, &|_, _| false).unwrap();
		let key = channel_key("test", channel);
		gateway.started(&key);
		gateway
			.bridge_mut(&key)
			.unwrap()
			.room
			.subscribe(1, "reader", 1, MembershipKind::Participant, "", 128, &|_| None)
			.unwrap();
	}
	let gateway = Rc::new(RefCell::new(gateway));
	let (delivered, mut deliveries) = tokio::sync::mpsc::channel(16);
	let (feed, worker) = crate::irc::feed::open(
		gateway.clone(),
		"test",
		None,
		move |key, effects| {
			for (_, _, notice) in effects.tells {
				if let Notice::Line { text, .. } = notice {
					delivered
						.try_send((key.to_owned(), text))
						.map_err(|_| "test delivery overflow")?;
				}
			}
			Ok(())
		},
		|| {},
	)
	.unwrap();
	let task = tokio::task::spawn_local(worker.run());
	let (socket, _) = listener.accept().await.unwrap();
	let mut server = BufReader::new(socket);
	for expected in ["NICK feed\r\n", "USER feed 0 * :bridge bot; admin: alice\r\n"] {
		let mut line = String::new();
		server.read_line(&mut line).await.unwrap();
		assert_eq!(line, expected);
	}
	server
		.get_mut()
		.write_all(b":server 001 feed :welcome\r\n")
		.await
		.unwrap();
	for channel in ["#a", "#b"] {
		let mut line = String::new();
		server.read_line(&mut line).await.unwrap();
		assert_eq!(line, format!("JOIN {channel}\r\n"));
		server
			.get_mut()
			.write_all(format!(":feed!u@host JOIN {channel}\r\n").as_bytes())
			.await
			.unwrap();
	}
	server
		.get_mut()
		.write_all(b":alice!u@host PRIVMSG #a :one\r\n:bob!u@host PRIVMSG #b :two\r\n")
		.await
		.unwrap();
	assert_eq!(deliveries.recv().await, Some((channel_key("test", "#a"), "one".into())));
	assert_eq!(deliveries.recv().await, Some((channel_key("test", "#b"), "two".into())));
	gateway.borrow_mut().part_bridge(&channel_key("test", "#a")).unwrap();
	feed.changed();
	let mut line = String::new();
	server.read_line(&mut line).await.unwrap();
	assert_eq!(line, "PART #a\r\n");
	server
		.get_mut()
		.write_all(b":bob!u@host PRIVMSG #b :still here\r\n")
		.await
		.unwrap();
	assert_eq!(
		deliveries.recv().await,
		Some((channel_key("test", "#b"), "still here".into()))
	);
	gateway.borrow_mut().part_bridge(&channel_key("test", "#b")).unwrap();
	feed.changed();
	line.clear();
	assert_eq!(server.read_line(&mut line).await.unwrap(), 0);
	feed.stop();
	task.await.unwrap().unwrap();
}
