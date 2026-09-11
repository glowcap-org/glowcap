use super::*;

#[tokio::test]
async fn member_channels_require_confirmation_and_old_handles_cannot_rejoin() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(10), scenario())
				.await
				.expect("IRC member deadline");
		})
		.await;
}
async fn scenario() {
	let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
	let endpoint = Endpoint::new("127.0.0.1", listener.local_addr().unwrap().port(), false).unwrap();
	let (member, worker) = crate::irc::member::open(endpoint, None, "alice", None).unwrap();
	let task = tokio::task::spawn_local(worker.run());
	let (socket, _) = listener.accept().await.unwrap();
	let mut server = BufReader::new(socket);
	for _ in 0..2 {
		let mut line = String::new();
		server.read_line(&mut line).await.unwrap();
	}
	server
		.get_mut()
		.write_all(b":server 001 alice :welcome\r\n")
		.await
		.unwrap();
	assert_eq!(member.ready().await.unwrap(), "alice");
	let one = member.join("#a").unwrap();
	let two = member.join("#b").unwrap();
	assert!(one.say("too early").is_err());
	for channel in ["#a", "#b"] {
		let mut line = String::new();
		server.read_line(&mut line).await.unwrap();
		assert_eq!(line, format!("JOIN {channel}\r\n"));
		server
			.get_mut()
			.write_all(format!(":alice!u@host JOIN {channel}\r\n").as_bytes())
			.await
			.unwrap();
	}
	one.ready().await.unwrap();
	two.ready().await.unwrap();
	one.part().unwrap();
	assert!(one.say("retired").is_err());
	assert!(
		member.join("#a").is_err(),
		"a replacement waits for the actual departure"
	);
	let mut line = String::new();
	server.read_line(&mut line).await.unwrap();
	assert_eq!(line, "PART #a :leaving the room\r\n");
	// A late JOIN from the retired attempt cannot reauthorize the handle.
	server
		.get_mut()
		.write_all(b":alice!u@host JOIN #a\r\n:alice!u@host PART #a :left\r\n")
		.await
		.unwrap();
	two.say("sibling").unwrap().wait().await.unwrap();
	line.clear();
	server.read_line(&mut line).await.unwrap();
	assert_eq!(line, "PRIVMSG #b sibling\r\n");
	let replacement = loop {
		match member.join("#a") {
			Ok(membership) => break membership,
			Err(_) => tokio::task::yield_now().await,
		}
	};
	assert!(one.say("old handle").is_err());
	assert!(replacement.say("not confirmed yet").is_err());
	line.clear();
	server.read_line(&mut line).await.unwrap();
	assert_eq!(line, "JOIN #a\r\n");
	server.get_mut().write_all(b":alice!u@host JOIN #a\r\n").await.unwrap();
	replacement.ready().await.unwrap();
	member.close().await.unwrap();
	task.await.unwrap().unwrap();
	assert!(two.say("closed").is_err());
	assert!(replacement.say("closed").is_err());
}
