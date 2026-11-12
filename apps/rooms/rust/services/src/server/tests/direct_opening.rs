//! One wire introduction waits for its exact offer and returns a usable inbox.
use super::*;

#[tokio::test]
async fn rooms_server_one_introduction_call_waits_for_its_inbox() {
	rooms_testing::local_set::run_within(Duration::from_secs(20), async {
		let temp = Scratch::create("single-introduction");
		let running = start(temp.to_path_buf(), tcp()).await;
		let alice_member = Member::listen().await;
		let alice = Client::new(alice_member.connect(&running.location).await, HostPlatform);
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
		let alice_dir = Directory::fetch(alice.clone()).await.unwrap();
		let bob_dir = Directory::fetch(bob.clone()).await.unwrap();
		let mut alice_name = alice_dir.registration();
		let alice_id = alice_name
			.register(
				"Alice",
				&glowcap::format_locator_uri(&alice_member.listener.locator().unwrap()).unwrap(),
				None,
			)
			.await
			.unwrap()
			.id;
		let mut bob_name = bob_dir.registration();
		let bob_id = bob_name.register("Bob", "127.0.0.1:9", None).await.unwrap().id;
		let inbox = alice.session().spawn_owned(|_, _| Ok("one opening".into())).unwrap();
		let introducing = introduce(&bob, &bob_dir, &alice_id, "one-opening");
		let asked = alice_name.next().await.unwrap().unwrap();
		assert_eq!(asked.registration, bob_id);
		assert_eq!(asked.opening.as_ref().unwrap().text().as_str(), Some("one-opening"));
		alice_dir
			.offer_inbox("Bob", &bob_id, "one-opening", &inbox)
			.await
			.unwrap();
		let received = introducing
			.await
			.unwrap()
			.expect("one introduce call must return the inbox");
		let Argument::Reference(inbox) = received.reply else {
			panic!("introduction did not return a capability")
		};
		let via = received.via.as_ref().expect("introduction must redeem Alice's handoff");
		assert_eq!(
			via.send(&inbox, "hello", &[]).await.unwrap().as_str(),
			Some("one opening")
		);
		// A fresh call that receives no offer settles once with a deadline failure.
		let timed_out = introduce(&bob, &bob_dir, &alice_id, "no-offer");
		let asked = alice_name.next().await.unwrap().unwrap();
		assert_eq!(asked.opening.as_ref().unwrap().text().as_str(), Some("no-offer"));
		tokio::time::pause();
		tokio::time::advance(Duration::from_millis(
			rooms_application::directory::introduction::WAIT_MS,
		))
		.await;
		let error = timed_out.await.unwrap().err().expect("introduction must fail");
		tokio::time::resume();
		assert_eq!(
			rooms_glowcap::client::binding_failure(&error).unwrap().code,
			rooms_application::failure::FailureCode::IntroductionTimedOut
		);
		drop(inbox);
		drop(received.via);
		drop(bob_name);
		drop(alice_name);
		bob_runtime.close(PendingWork::Cancel).await.unwrap();
		alice_member.close().await;
		running.stop.send(()).unwrap();
		running.task.await.unwrap().unwrap();
	})
	.await;
}

/// A held introduction takes no seat in the work queue. With all of them
/// held, the offer that settles one still finds its seat.
#[tokio::test]
async fn held_introductions_at_their_cap_leave_room_for_the_offer_that_settles_one() {
	use crate::server::introductions::MAX_PER_CALLER;
	use rooms_application::directory::introduction::MAX_OUTSTANDING;
	rooms_testing::local_set::run_within(Duration::from_secs(20), async {
		let temp = Scratch::create("introduction-work");
		let rates = format!("introduction=33/33,recipient={MAX_OUTSTANDING}/{MAX_OUTSTANDING}");
		let settings = rooms_application::admission::Settings::parse(
			|key| (key == "admission-rates").then(|| rates.clone()),
			8192,
			1,
		)
		.unwrap();
		let running = start_with_admission(temp.to_path_buf(), tcp(), Asked::default(), settings).await;
		let alice_member = Member::listen().await;
		let alice = Client::new(alice_member.connect(&running.location).await, HostPlatform);
		let alice_dir = Directory::fetch(alice.clone()).await.unwrap();
		let mut alice_name = alice_dir.registration();
		let alice_id = alice_name
			.register(
				"Alice",
				&glowcap::format_locator_uri(&alice_member.listener.locator().unwrap()).unwrap(),
				None,
			)
			.await
			.unwrap()
			.id;
		let inbox = alice.session().spawn_owned(|_, _| Ok(Argument::Void)).unwrap();
		let mut callers = Vec::new();
		let mut waiting = Vec::new();
		for caller in 0..MAX_OUTSTANDING / MAX_PER_CALLER {
			let runtime = runtime().await;
			let client = Client::new(
				runtime
					.connect(&glowcap::parse_locator(&running.location).unwrap(), Default::default())
					.await
					.unwrap(),
				HostPlatform,
			);
			let directory = Directory::fetch(client.clone()).await.unwrap();
			let mut name = directory.registration();
			let nick = format!("Bob{caller}");
			let id = name.register(&nick, "127.0.0.1:9", None).await.unwrap().id;
			for index in 0..MAX_PER_CALLER {
				let opening = format!("{caller}-{index}");
				waiting.push((
					nick.clone(),
					id.clone(),
					opening.clone(),
					introduce(&client, &directory, &alice_id, &opening),
				));
				let asked = alice_name.next().await.unwrap().unwrap();
				assert_eq!(asked.opening.as_ref().unwrap().text().as_str(), Some(opening.as_str()));
			}
			callers.push((runtime, name));
		}
		assert_eq!(waiting.len(), MAX_OUTSTANDING);
		let (nick, id, opening, held) = waiting.swap_remove(0);
		alice_dir.offer_inbox(&nick, &id, &opening, &inbox).await.unwrap();
		held.await.unwrap().expect("the offered introduction must settle");
		alice.session().close(PendingWork::Cancel).await.unwrap();
		for (_, _, _, call) in waiting {
			call.await
				.unwrap()
				.err()
				.expect("a held introduction ends with its target");
		}
		drop((inbox, alice_name));
		for (runtime, name) in callers {
			drop(name);
			runtime.close(PendingWork::Cancel).await.unwrap();
		}
		alice_member.close().await;
		running.stop.send(()).unwrap();
		running.task.await.unwrap().unwrap();
	})
	.await;
}

fn introduce(
	client: &Client<HostPlatform>,
	directory: &Directory<HostPlatform>,
	id: &rooms_application::directory::registration::Id,
	opening: &str,
) -> tokio::task::JoinHandle<glowcap::Result<glowcap::SendRedeemingResult>> {
	let (client, reference, id, opening) = (
		client.clone(),
		directory.reference().clone(),
		id.clone(),
		opening.to_owned(),
	);
	tokio::task::spawn_local(async move {
		client
			.session()
			.send_redeeming(
				&reference,
				rooms_application::protocol_data::INTRODUCE,
				&["Alice".into(), id.as_str().into(), opening.into()],
			)
			.await
	})
}

/// A caller with no name is told so. It does not hear that its target left,
/// and the refusal costs it nothing.
#[tokio::test]
async fn an_introduction_from_a_caller_with_no_name_is_refused_as_not_registered() {
	rooms_testing::local_set::run_within(Duration::from_secs(20), async {
		let temp = Scratch::create("introduction-unregistered");
		let running = start(temp.to_path_buf(), tcp()).await;
		let alice_member = Member::listen().await;
		let alice = Client::new(alice_member.connect(&running.location).await, HostPlatform);
		let alice_dir = Directory::fetch(alice.clone()).await.unwrap();
		let mut alice_name = alice_dir.registration();
		let alice_id = alice_name
			.register(
				"Alice",
				&glowcap::format_locator_uri(&alice_member.listener.locator().unwrap()).unwrap(),
				None,
			)
			.await
			.unwrap()
			.id;
		let bob_runtime = runtime().await;
		let bob = Client::new(
			bob_runtime
				.connect(&glowcap::parse_locator(&running.location).unwrap(), Default::default())
				.await
				.unwrap(),
			HostPlatform,
		);
		let bob_dir = Directory::fetch(bob.clone()).await.unwrap();
		let refused = introduce(&bob, &bob_dir, &alice_id, "0")
			.await
			.unwrap()
			.err()
			.expect("an unregistered caller is refused");
		assert_eq!(
			rooms_glowcap::client::binding_failure(&refused).unwrap().code,
			rooms_application::failure::FailureCode::NotRegistered
		);
		drop(alice_name);
		bob_runtime.close(PendingWork::Cancel).await.unwrap();
		alice.session().close(PendingWork::Cancel).await.unwrap();
		alice_member.close().await;
		running.stop.send(()).unwrap();
		running.task.await.unwrap().unwrap();
	})
	.await;
}

#[tokio::test]
async fn introduction_capacity_refusal_preserves_admission_and_retirement_settles_waiters() {
	rooms_testing::local_set::run_within(Duration::from_secs(20), async {
		let temp = Scratch::create("introduction-capacity");
		let settings = rooms_application::admission::Settings::parse(
			|key| (key == "admission-rates").then(|| "introduction=33/33,recipient=256/256".into()),
			8192,
			1,
		)
		.unwrap();
		let running = start_with_admission(temp.to_path_buf(), tcp(), Asked::default(), settings).await;
		let alice_member = Member::listen().await;
		let alice = Client::new(alice_member.connect(&running.location).await, HostPlatform);
		let bob_runtime = runtime().await;
		let bob = Client::new(
			bob_runtime
				.connect(&glowcap::parse_locator(&running.location).unwrap(), Default::default())
				.await
				.unwrap(),
			HostPlatform,
		);
		let alice_dir = Directory::fetch(alice.clone()).await.unwrap();
		let bob_dir = Directory::fetch(bob.clone()).await.unwrap();
		let mut alice_name = alice_dir.registration();
		let alice_id = alice_name
			.register(
				"Alice",
				&glowcap::format_locator_uri(&alice_member.listener.locator().unwrap()).unwrap(),
				None,
			)
			.await
			.unwrap()
			.id;
		let mut bob_name = bob_dir.registration();
		let bob_id = bob_name.register("Bob", "127.0.0.1:9", None).await.unwrap().id;
		let inbox = alice.session().spawn_owned(|_, _| Ok(Argument::Void)).unwrap();
		let mut waiting = std::collections::VecDeque::new();
		for index in 0..32 {
			let opening = index.to_string();
			waiting.push_back(introduce(&bob, &bob_dir, &alice_id, &opening));
			let asked = alice_name.next().await.unwrap().unwrap();
			assert_eq!(asked.opening.as_ref().unwrap().text().as_str(), Some(opening.as_str()));
		}
		let refused = introduce(&bob, &bob_dir, &alice_id, "overflow")
			.await
			.unwrap()
			.err()
			.expect("introduction must fail");
		assert_eq!(
			rooms_glowcap::client::binding_failure(&refused).unwrap().code,
			rooms_application::failure::FailureCode::AdmissionBusy
		);
		alice_dir.offer_inbox("Bob", &bob_id, "0", &inbox).await.unwrap();
		let acquired = waiting.pop_front().unwrap().await.unwrap().unwrap();
		drop(acquired);
		// The refused call did not consume the final token. Freeing one slot
		// admits this call immediately, without waiting for quota to refill.
		let admitted = introduce(&bob, &bob_dir, &alice_id, "last-token");
		let asked = alice_name.next().await.unwrap().unwrap();
		assert_eq!(asked.opening.as_ref().unwrap().text().as_str(), Some("last-token"));
		waiting.push_back(admitted);
		// Retiring the original target wakes all held calls, with no retry.
		alice.session().close(PendingWork::Cancel).await.unwrap();
		while let Some(call) = waiting.pop_front() {
			let error = call.await.unwrap().err().expect("introduction must fail");
			assert_eq!(
				rooms_glowcap::client::binding_failure(&error).unwrap().code,
				rooms_application::failure::FailureCode::PeerOffline
			);
		}
		drop((inbox, alice_name, bob_name));
		bob_runtime.close(PendingWork::Cancel).await.unwrap();
		alice_member.close().await;
		running.stop.send(()).unwrap();
		running.task.await.unwrap().unwrap();
	})
	.await;
}
