//! The route a member registers is the route the handoffs of its inbox name,
//! and a registration the directory or the Host refuses leaves the standing
//! one, and the route its handoffs name, as they were.
use super::*;

#[tokio::test]
async fn rooms_server_hands_out_a_members_inbox_at_the_route_it_registered() {
	rooms_testing::local_set::run_within(Duration::from_secs(30), registered_route()).await;
}

async fn registered_route() {
	let temp = Scratch::create("server");
	let running = start(temp.to_path_buf(), tcp()).await;
	let dial = glowcap::parse_locator(&running.location).unwrap();
	let alice_member = Member::listen().await;
	let alice = Client::new(alice_member.connect(&running.location).await, HostPlatform);
	let bob_runtime = runtime().await;
	let bob = Client::new(
		bob_runtime.connect(&dial, ConnectOptions::default()).await.unwrap(),
		HostPlatform,
	);
	let (alice_dir, bob_dir) = (
		Directory::fetch(alice.clone()).await.unwrap(),
		Directory::fetch(bob.clone()).await.unwrap(),
	);
	let mut bob_name = bob_dir.registration();
	bob_name.register("Bob", "127.0.0.1:9", None).await.unwrap();
	// A port nothing listens on, so a handoff naming it cannot be redeemed,
	// while Alice's hello names her live listener.
	let dead = {
		let socket = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
		socket.local_addr().unwrap().port()
	};
	let dead = glowcap::format_locator_uri(&glowcap::tcp::locator("127.0.0.1", dead)).unwrap();
	let live = glowcap::format_locator_uri(&alice_member.listener.locator().unwrap()).unwrap();
	let inbox = alice.session().spawn_owned(|_, _| Ok("alice".into())).unwrap();
	let introduce =
		async |alice_name: &mut rooms_glowcap::client::directory::registration::Registration<HostPlatform>| {
			let introducing = {
				let bob_dir = bob_dir.clone();
				tokio::task::spawn_local(async move { bob_dir.introduce("Alice", None).await })
			};
			let asked = alice_name.next().await.unwrap().expect("an inbox request");
			let opening = asked.opening.as_ref().unwrap().text().as_str().unwrap().to_owned();
			alice_dir
				.offer_inbox("Bob", &asked.registration, &opening, &inbox)
				.await
				.unwrap();
			introducing.await.unwrap()
		};

	// The handoff names the registered route, not the hello.
	let mut alice_name = alice_dir.registration();
	alice_name.register("Alice", &dead, None).await.unwrap();
	assert!(introduce(&mut alice_name).await.is_err(), "the handoff named the hello");
	// Registering again moves the handoffs to the new route.
	alice_name.take_name().unwrap();
	let standing = alice_name.register("Alice", &live, None).await.unwrap().id;
	let introduction = introduce(&mut alice_name).await.unwrap();
	let answer = introduction
		.session()
		.send(&introduction.inbox, "hello", &[])
		.await
		.unwrap();
	assert_eq!(answer.as_str(), Some("alice"));
	drop(introduction);

	// An identity route whose WebRTC door proves another key is refused
	// before anything is filed, and so is a taken name. Either way the
	// standing registration and the route its handoffs name stay.
	let other =
		glowcap::format_locator_uri(&glowcap::Locator::bare(glowcap::TRANSPORT_WEBRTC, &"b".repeat(64))).unwrap();
	let mismatched = glowcap::format_locator_uri(
		&glowcap::Locator::bare(glowcap::TRANSPORT_ID, &"a".repeat(64))
			.with_hint(glowcap::HINT_VIA, glowcap::HintValue::String(other)),
	)
	.unwrap();
	let mut attempt = alice_dir.registration();
	let refused = attempt.register("Alice", &mismatched, None).await.unwrap_err();
	assert!(refused.to_string().contains("handoffs"), "{refused}");
	let mut attempt = alice_dir.registration();
	let taken = attempt.register("Bob", &dead, None).await.unwrap_err();
	assert!(taken.to_string().contains("nick-taken"), "{taken}");
	assert_eq!(bob_dir.member_registration("Alice").await.unwrap(), standing);
	let introduction = introduce(&mut alice_name).await.unwrap();
	let answer = introduction
		.session()
		.send(&introduction.inbox, "hello", &[])
		.await
		.unwrap();
	assert_eq!(answer.as_str(), Some("alice"));

	drop((introduction, attempt, alice_name, bob_name, inbox));
	drop((alice_dir, bob_dir));
	closing_tolerated(alice.session().close(PendingWork::Cancel).await);
	closing_tolerated(bob.session().close(PendingWork::Cancel).await);
	running.stop.send(()).unwrap();
	running.task.await.unwrap().unwrap();
	assert!(running.notices.borrow().is_empty(), "{:?}", running.notices.borrow());
	alice_member.close().await;
	bob_runtime.close(PendingWork::Cancel).await.unwrap();
	drop(temp);
}
