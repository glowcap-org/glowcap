//! Exercise the gateway through the same Config/run path as rooms-server.
mod operator;
use super::super::{Temp, runtime, start_with, tcp};
use crate::server::{Asked, Config};
use glowcap::{Argument, ConnectOptions, PendingWork, Ref};
use std::{cell::RefCell, rc::Rc, time::Duration};
use tokio::{
	io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
	sync::mpsc,
};

fn cap(value: Argument) -> Ref {
	match value {
		Argument::Reference(cap) => cap,
		other => panic!("expected capability, got {other:?}"),
	}
}
fn member(value: Argument) -> Ref {
	match value {
		Argument::List(mut values) => cap(values.remove(0)),
		other => panic!("expected subscription, got {other:?}"),
	}
}

#[tokio::test]
async fn host_irc_gateway_seats_two_channels_and_retires_exact_capabilities() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(30), scenario())
				.await
				.expect("host gateway deadline");
		})
		.await;
}
async fn scenario() {
	let config = Config::parse(["--irc".into(), "--transport=tcp".into()], |_| None)
		.unwrap()
		.unwrap();
	assert!(config.asked.irc);
	let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
	let port = listener.local_addr().unwrap().port();
	let (said, mut heard) = mpsc::channel(32);
	let wire = Rc::new(RefCell::new(Vec::new()));
	let observed = wire.clone();
	let (registering, mut attempted) = mpsc::channel(2);
	let reject = Rc::new(tokio::sync::Notify::new());
	let rejection = reject.clone();
	let (stop_irc, mut stopping) = tokio::sync::oneshot::channel::<()>();
	let irc = tokio::task::spawn_local(async move {
		let mut clients = tokio::task::JoinSet::new();
		loop {
			tokio::select! {
				_ = &mut stopping => break,
				accepted = listener.accept() => {
					let (socket, _) = accepted.unwrap();
					let said = said.clone();
					let wire = observed.clone();
					let (registering, reject) = (registering.clone(), rejection.clone());
					clients.spawn_local(async move {
						let mut socket = BufReader::new(socket);
						let mut nick = String::new();
						loop {
							let mut line = String::new();
							if socket.read_line(&mut line).await.unwrap_or(0) == 0 { break; }
							let message = rooms_application::server::irc::protocol::parse_line(line.trim_end()).unwrap();
							let answer = match message.command.as_str() {
								"NICK" => { nick = message.params[0].clone(); String::new() },
								"USER" if nick == "taken" => {
									registering.send(()).await.unwrap();
									reject.notified().await;
									format!(":server 433 * {nick} :nickname in use\r\n")
								},
								"USER" => format!(":server 001 {nick} :welcome\r\n"),
								"JOIN" => format!(":{nick}!u@host JOIN {}\r\n:server 366 {nick} {} :end\r\n", message.params[0], message.params[0]),
								"PART" => format!(":{nick}!u@host PART {}\r\n", message.params[0]),
								"PRIVMSG" => { said.send((nick.clone(), message.params.clone())).await.unwrap(); String::new() },
								_ => String::new(),
							};
							wire.borrow_mut().push((nick.clone(), message.command.clone(), message.params.clone()));
							if !answer.is_empty() && socket.get_mut().write_all(answer.as_bytes()).await.is_err() { break; }
						}
					});
				}
				Some(result) = clients.join_next(), if !clients.is_empty() => { result.unwrap(); }
			}
		}
		while let Some(result) = clients.join_next().await {
			result.unwrap();
		}
	});
	let temp = Temp::new();
	let asked = Asked {
		irc: true,
		operator: true,
		diagnostics: true,
		trace: true,
		..Default::default()
	};
	let running = start_with(temp.0.clone(), tcp(), asked.clone()).await;
	let viewer = super::trace::Viewer::subscribe(running.trace.as_deref().unwrap()).await;
	let runtime = runtime().await;
	let session = runtime
		.connect(
			&glowcap::parse_locator(&running.location).unwrap(),
			ConnectOptions::default(),
		)
		.await
		.unwrap();
	let swiss = running
		.capabilities
		.iter()
		.find(|cap| cap.capability.id == "irc")
		.unwrap()
		.swiss
		.clone();
	let gateway = session.fetch(&swiss).await.unwrap();
	let choice = serde_json::json!({
		"name": "net",
		"host": "127.0.0.1",
		"port": port.to_string(),
		"nick": "feed",
		"realname": "Rooms bridge bot; admin: fixture-admin",
		"tls": "off"
	})
	.to_string();
	assert_eq!(
		session
			.send(&gateway, "openConnection", &[choice.into()])
			.await
			.unwrap(),
		Argument::from("net")
	);
	let network = cap(session.send(&gateway, "connection", &["net".into()]).await.unwrap());
	for channel in ["a", "b"] {
		let raw = serde_json::json!({"channel":channel,"permission":"on"}).to_string();
		assert_eq!(
			session.send(&network, "addLease", &[raw.into()]).await.unwrap(),
			Argument::from(format!("net/#{channel}"))
		);
	}
	let directory = session.fetch("directory").await.unwrap();
	let listed = session
		.send(&directory, rooms_application::directory::LIST, &[])
		.await
		.unwrap();
	let rows = rooms_application::directory::rooms(&rooms_glowcap::Value(&listed)).unwrap();
	let publication = rows
		.iter()
		.find(|row| row.name.text().as_str() == Some("net/#a"))
		.unwrap();
	let publication = publication.id.text().as_str().unwrap().to_owned();
	let saved = session
		.send(
			&directory,
			rooms_application::directory::creation::LINK_PUBLICATION,
			&[publication.clone().into()],
		)
		.await
		.unwrap();
	assert!(saved.as_str().is_some_and(|uri| uri.starts_with("ocapn://")));
	let mut memberships = Vec::new();
	let notices = Rc::new(RefCell::new(Vec::new()));
	for channel in ["a", "b"] {
		let room = cap(session
			.send(&directory, "enter", &[format!("net/#{channel}").into()])
			.await
			.unwrap());
		let inbox = {
			let notices = notices.clone();
			session
				.spawn_owned(move |_, args| {
					notices.borrow_mut().push(args.to_vec());
					Ok(Argument::Void)
				})
				.unwrap()
		};
		let held = member(
			session
				.send(&room, "subscribe", &["alice".into(), Argument::Reference(inbox)])
				.await
				.unwrap(),
		);
		session
			.send(&held, "post", &[format!("hello {channel}").into()])
			.await
			.unwrap();
		let (nick, line) = heard.recv().await.unwrap();
		assert_eq!(nick, "alice");
		assert_eq!(line, [format!("#{channel}"), format!("hello {channel}")]);
		memberships.push(held);
	}
	assert!(
		notices
			.borrow()
			.iter()
			.any(|args| args.get(1).and_then(Argument::as_str) == Some("hello b"))
	);
	session
		.send(&memberships[0], "submitBridgeForm", &["disconnect".into(), "{}".into()])
		.await
		.unwrap();
	assert!(
		session
			.send(&memberships[1], "post", &["must not reach IRC".into()])
			.await
			.unwrap_err()
			.to_string()
			.contains("Rooms only")
	);
	session
		.send(
			&memberships[1],
			"submitBridgeForm",
			&["link".into(), r#"{"nick":"bob"}"#.into()],
		)
		.await
		.unwrap();
	for membership in &memberships {
		session
			.send(membership, "post", &["new identity".into()])
			.await
			.unwrap();
		assert_eq!(heard.recv().await.unwrap().0, "bob");
	}
	// A failed change restores through the surviving sibling even when the
	// channel whose form admitted the change has already left.
	let before = wire.borrow().len();
	let changing = {
		let (session, member) = (session.borrowed(), memberships[0].clone());
		tokio::task::spawn_local(async move {
			session
				.send(
					&member,
					"submitBridgeForm",
					&["link".into(), r#"{"nick":"taken"}"#.into()],
				)
				.await
		})
	};
	attempted.recv().await.unwrap();
	session.send(&memberships[0], "leave", &[]).await.unwrap();
	reject.notify_one();
	assert!(
		changing
			.await
			.unwrap()
			.unwrap_err()
			.to_string()
			.contains("already in use")
	);
	assert!(
		wire.borrow()[before..]
			.iter()
			.any(|(nick, verb, _)| nick == "bob" && verb == "NICK"),
		"prior identity was not restored before answering the failed change"
	);
	session
		.send(&memberships[1], "post", &["restored sibling".into()])
		.await
		.unwrap();
	assert_eq!(heard.recv().await.unwrap().0, "bob");
	let failures: Vec<_> = running.notices.borrow_mut().drain(..).collect();
	assert!(!failures.is_empty());
	assert!(
		failures
			.iter()
			.all(|notice| notice.contains("IRC nickname \"taken\" is already in use")),
		"{failures:?}"
	);
	session.send(&network, "removeLease", &["#a".into()]).await.unwrap();
	assert!(
		session
			.send(
				&directory,
				rooms_application::directory::creation::LINK_PUBLICATION,
				&[publication.into()]
			)
			.await
			.is_err(),
		"a retired publication cannot return a replacement link"
	);
	assert!(
		session
			.send(&memberships[0], "post", &["stale".into()])
			.await
			.unwrap_err()
			.to_string()
			.contains("room-retired")
	);
	session
		.send(&memberships[1], "post", &["sibling survives".into()])
		.await
		.unwrap();
	assert_eq!(heard.recv().await.unwrap().1[1], "sibling survives");
	// The sole remaining channel keeps the chosen identity and channel lease
	// across capability replacement. No PART, JOIN or new registration belongs
	// to replacing the Rooms inbox; the old capability must still retire.
	for _ in 0..3 {
		let before = wire.borrow().len();
		let room = cap(session.send(&directory, "enter", &["net/#b".into()]).await.unwrap());
		let inbox = session.spawn_owned(|_, _| Ok(Argument::Void)).unwrap();
		let replacement = member(
			session
				.send(&room, "subscribe", &["alice".into(), inbox.into()])
				.await
				.unwrap(),
		);
		assert!(
			session
				.send(&memberships[1], "post", &["stale replacement".into()])
				.await
				.unwrap_err()
				.to_string()
				.contains("not-room-member")
		);
		memberships[1] = replacement;
		session
			.send(&memberships[1], "post", &["same identity".into()])
			.await
			.unwrap();
		assert_eq!(
			heard.recv().await.unwrap(),
			("bob".into(), vec!["#b".into(), "same identity".into()])
		);
		assert!(
			wire.borrow()[before..]
				.iter()
				.all(|(nick, verb, params)| (nick != "bob" || verb == "PRIVMSG")
					&& !(verb == "PART" && params.first().is_some_and(|c| c == "#b"))),
			"replacing a reader changed its IRC channel or identity"
		);
	}

	// Ending the last participant ends this identity incarnation. A pending
	// failed change must not restore its credentials into a newly joined one.
	let before = wire.borrow().len();
	let changing = {
		let (session, member) = (session.borrowed(), memberships[1].clone());
		tokio::task::spawn_local(async move {
			session
				.send(
					&member,
					"submitBridgeForm",
					&["link".into(), r#"{"nick":"taken"}"#.into()],
				)
				.await
		})
	};
	attempted.recv().await.unwrap();
	session.send(&memberships[1], "leave", &[]).await.unwrap();
	let room = cap(session.send(&directory, "enter", &["net/#b".into()]).await.unwrap());
	let inbox = session.spawn_owned(|_, _| Ok(Argument::Void)).unwrap();
	memberships[1] = member(
		session
			.send(&room, "subscribe", &["alice".into(), inbox.into()])
			.await
			.unwrap(),
	);
	reject.notify_one();
	assert!(changing.await.unwrap().is_err());
	session
		.send(&memberships[1], "post", &["new incarnation".into()])
		.await
		.unwrap();
	assert_eq!(heard.recv().await.unwrap().0, "alice");
	assert!(
		!wire.borrow()[before..]
			.iter()
			.any(|(nick, verb, _)| nick == "bob" && verb == "NICK")
	);

	let operator_token = running
		.capabilities
		.iter()
		.find(|cap| cap.capability.id == "operator")
		.unwrap()
		.swiss
		.clone();
	let operator = session.fetch(&operator_token).await.unwrap();
	let diagnostic_token = running
		.capabilities
		.iter()
		.find(|cap| cap.capability.id == "diagnostics")
		.unwrap()
		.swiss
		.clone();
	let diagnostic = session.fetch(&diagnostic_token).await.unwrap();
	let snapshot = session.send(&diagnostic, "snapshot", &[]).await.unwrap();
	let diagnostic_rows = super::rows(&snapshot);
	assert!(
		diagnostic_rows
			.iter()
			.any(|row| row[0].as_str() == Some("room") && row[1].as_str() == Some("net/#b"))
	);
	assert!(
		diagnostic_rows
			.iter()
			.any(|row| row[0].as_str() == Some("occupant") && row[1].as_str() == Some("alice"))
	);
	viewer
		.heard(r#""meta":{"label":"alice"}"#, Duration::from_secs(5))
		.await;

	let old_reference = operator::member_reference(&session, &operator).await;
	let issued = session
		.send(&operator, "giveSteward", &["net/#b".into()])
		.await
		.unwrap();
	let Argument::List(row) = issued else {
		panic!("stewardship row");
	};
	let publication_id = row[0].clone();
	let token = token(row[5].as_str().unwrap());
	let moderator = session.fetch(&token).await.unwrap();
	let governs = session.send(&moderator, "governs", &[]).await.unwrap();
	assert!(
		session
			.send(&moderator, "kick", &["irc/somebody".into()])
			.await
			.is_err()
	);
	assert_eq!(
		session
			.send(
				&operator,
				"revokeRoomAuthority",
				&["steward".into(), token.clone().into()]
			)
			.await
			.unwrap(),
		Argument::Void
	);
	assert!(
		session
			.send(&moderator, "governs", &[])
			.await
			.unwrap_err()
			.to_string()
			.contains("not-steward")
	);
	let issued = session.send(&operator, "giveSteward", &[publication_id]).await.unwrap();
	let Argument::List(row) = issued else {
		panic!("stewardship row");
	};
	let moderator_token = self::token(row[5].as_str().unwrap());
	assert_ne!(moderator_token, token);
	let moderator = session.fetch(&moderator_token).await.unwrap();
	assert_eq!(session.send(&moderator, "governs", &[]).await.unwrap(), governs);
	let invitation = cap(session
		.send(&memberships[1], "mintInvitation", &["observer".into()])
		.await
		.unwrap());
	let receipt = "0123456789abcdef0123456789abcdef";
	let first = cap(session
		.send(&invitation, "claimInvitation", &[receipt.into()])
		.await
		.unwrap());
	let again = cap(session
		.send(&invitation, "claimInvitation", &[receipt.into()])
		.await
		.unwrap());
	assert!(
		session
			.send(
				&invitation,
				"claimInvitation",
				&["ffffffffffffffffffffffffffffffff".into()]
			)
			.await
			.is_err()
	);
	let inbox = session.spawn_owned(|_, _| Ok(Argument::Void)).unwrap();

	assert!(
		session
			.send(
				&again,
				"subscribe",
				&["irc/reserved".into(), Argument::Reference(inbox.clone())]
			)
			.await
			.is_err()
	);
	let observer = member(
		session
			.send(
				&again,
				"subscribe",
				&["alice".into(), Argument::Reference(inbox.clone())],
			)
			.await
			.unwrap(),
	);
	assert_eq!(
		session.send(&observer, "membershipKind", &[]).await.unwrap(),
		Argument::from("observer")
	);
	assert!(
		session
			.send(&first, "subscribe", &["alice".into(), Argument::Reference(inbox)])
			.await
			.is_err()
	);
	assert!(session.send(&observer, "post", &["read only".into()]).await.is_err());
	assert!(
		session
			.send(&observer, "mintInvitation", &["participant".into()])
			.await
			.is_err()
	);

	assert_eq!(
		session.send(&observer, "bridgeForm", &[]).await.unwrap(),
		Argument::Void
	);
	assert!(
		session
			.send(
				&observer,
				"submitBridgeForm",
				&["link".into(), r#"{"nick":"observer"}"#.into()]
			)
			.await
			.is_err()
	);
	assert_ne!(operator::member_reference(&session, &operator).await, old_reference);
	assert!(
		session
			.send(&operator, "releaseOperatorReference", &[old_reference.into()])
			.await
			.is_err()
	);
	assert_eq!(
		session.send(&observer, "membershipKind", &[]).await.unwrap(),
		Argument::from("observer")
	);
	session.send(&moderator, "kick", &["alice".into()]).await.unwrap();
	assert!(session.send(&observer, "membershipKind", &[]).await.is_err());

	viewer.heard(r#""meta":{"label":null}"#, Duration::from_secs(5)).await;
	let snapshot = session.send(&diagnostic, "snapshot", &[]).await.unwrap();
	assert!(
		!super::rows(&snapshot)
			.iter()
			.any(|row| row[0].as_str() == Some("occupant") && row[1].as_str() == Some("alice"))
	);
	let exposed = format!("{snapshot:?}");
	assert!(!exposed.contains(&moderator_token));
	viewer.leave().await;

	// Restart with the saved lease and issuance, before exercising close.
	session.close(PendingWork::Cancel).await.unwrap();
	running.stop.send(()).unwrap();
	running.task.await.unwrap().unwrap();
	assert!(running.notices.borrow().is_empty(), "{:?}", running.notices.borrow());
	let running = start_with(temp.0.clone(), tcp(), asked).await;
	let session = runtime
		.connect(
			&glowcap::parse_locator(&running.location).unwrap(),
			ConnectOptions::default(),
		)
		.await
		.unwrap();
	let moderator = session.fetch(&moderator_token).await.unwrap();
	assert_eq!(session.send(&moderator, "governs", &[]).await.unwrap(), governs);
	assert!(session.fetch(&token).await.is_err());
	let gateway = session.fetch(&swiss).await.unwrap();
	let network = cap(session.send(&gateway, "connection", &["net".into()]).await.unwrap());
	let operator = session.fetch(&operator_token).await.unwrap();
	operator::scenario(&session, &operator, &network, &temp.0, &moderator).await;
	session.send(&network, "closeConnection", &[]).await.unwrap();
	assert!(
		session
			.send(&network, "addLease", &[r#"{"channel":"c"}"#.into()])
			.await
			.is_err()
	);
	session.close(PendingWork::Cancel).await.unwrap();
	running.stop.send(()).unwrap();
	running.task.await.unwrap().unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
	stop_irc.send(()).unwrap();
	irc.await.unwrap();
	assert!(running.notices.borrow().is_empty(), "{:?}", running.notices.borrow());
}

fn token(link: &str) -> String {
	let parsed = glowcap::parse_sturdyref(link, glowcap::CaptpVersion::V1_0).unwrap();
	String::from_utf8(parsed.swissnum).unwrap()
}
