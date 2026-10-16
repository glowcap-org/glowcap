//! A room's subject can name an object its member hosts. The room keeps the
//! link across a restart without ever calling it, and a member who arrives
//! later redeems it and calls the object directly.
use super::*;
use rooms_application::room::subject::Invalid;

#[tokio::test]
async fn a_linked_subject_survives_a_restart_and_a_later_member_calls_it() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(30), linked_subject())
				.await
				.expect("linked subject deadline");
		})
		.await;
}

async fn linked_subject() {
	let temp = Temp::new();
	let running = start(temp.0.clone(), tcp()).await;

	// Alice hosts the board on her own listener and makes it the subject.
	let alice = super::super::Member::listen().await;
	let swiss = alice
		.listener
		.host()
		.publish_durable(|| {
			Box::new(|verb, _| match verb {
				"describe" => Ok("three moves in".into()),
				_ => Err(format!("the board has no method {verb}")),
			})
		})
		.unwrap();
	let board = glowcap::format_sturdyref(
		&alice.listener.locator().unwrap(),
		swiss.as_bytes(),
		glowcap::CaptpVersion::V1_0,
	)
	.unwrap();
	let alice_client = Client::new(alice.connect(&running.location).await, HostPlatform);
	let directory = Directory::fetch(alice_client.clone()).await.unwrap();
	let (room, mut lines, _, _) = join(&alice_client, directory.open("Chess").await.unwrap(), "Alice").await;
	// A link shaped like a sturdyref that does not parse as one is refused
	// by the server for that reason, and nobody hears a change: the next
	// subject heard is the one set after it.
	let unparsed = Subject::new("the board".into(), Some("ocapn://nowhere".into())).unwrap();
	let refused = room.set_subject(&unparsed).await.unwrap_err().to_string();
	assert!(refused.contains(&Invalid::LinkUnreadable.to_string()), "{refused}");
	let subject = Subject::new("the board".into(), Some(board.clone())).unwrap();
	room.set_subject(&subject).await.unwrap();
	let heard = next(&mut lines).await;
	assert_eq!(heard.facts().and_then(|facts| facts.subject.as_deref()), Some(&subject));
	room.leave().await.unwrap();
	drop((room, lines, directory));
	closing_tolerated(alice_client.session().close(PendingWork::Cancel).await);
	running.stop.send(()).unwrap();
	running.task.await.unwrap().unwrap();
	assert!(running.notices.borrow().is_empty(), "{:?}", running.notices.borrow());

	// After a restart, Bob arrives, reads the subject, and calls the board on
	// Alice's host. The room server is not on that path.
	let running = start(temp.0.clone(), tcp()).await;
	let bob_runtime = runtime().await;
	let bob = Client::new(
		bob_runtime
			.connect(
				&glowcap::parse_locator(&running.location).unwrap(),
				ConnectOptions::default(),
			)
			.await
			.unwrap(),
		HostPlatform,
	);
	let directory = Directory::fetch(bob.clone()).await.unwrap();
	let (room, mut lines, _, _) = join(&bob, directory.open("Chess").await.unwrap(), "Bob").await;
	let told = loop {
		let line = next(&mut lines).await;
		if let Some(subject) = line.facts().and_then(|facts| facts.subject.as_deref().cloned()) {
			break subject;
		}
	};
	assert_eq!(told, subject);
	// The link names Alice's host, so Bob redeems it through his own Host,
	// which dials her. The room server's session would refuse it.
	let redeemed = bob_runtime.host().enliven(told.link().unwrap()).await.unwrap();
	let answer = bob_runtime.host().send(&redeemed, "describe", &[]).await.unwrap();
	assert_eq!(answer.as_str(), Some("three moves in"));

	drop((room, lines, directory, redeemed));
	closing_tolerated(bob.session().close(PendingWork::Cancel).await);
	running.stop.send(()).unwrap();
	running.task.await.unwrap().unwrap();
	assert!(running.notices.borrow().is_empty(), "{:?}", running.notices.borrow());
	bob_runtime.close(PendingWork::Cancel).await.unwrap();
	alice.close().await;
}
