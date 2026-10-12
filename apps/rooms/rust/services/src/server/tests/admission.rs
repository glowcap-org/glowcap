//! Actual native dispatch, isolation, cleanup and steady crowded-room cost.
use super::*;
use rooms_glowcap::client::room::Room;
#[tokio::test]
async fn refused_post_preserves_membership_and_other_peer_and_cleanup_progress() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let temp = Temp::new();
			let running = start(temp.0.clone(), tcp()).await;
			let runtime = runtime().await;
			let locator = glowcap::parse_locator(&running.location).unwrap();
			let first = Client::new(
				runtime.connect(&locator, Default::default()).await.unwrap(),
				HostPlatform,
			);
			let directory = Directory::fetch(first.clone()).await.unwrap();
			let entrance = directory.open("Admission").await.unwrap();
			let (member, _messages) = Room::subscribe(first.clone(), entrance, "Alice", Default::default())
				.await
				.unwrap();
			for _ in 0..rooms_application::admission::Class::Message.default_rate().burst() {
				member.say("hello").await.unwrap();
			}
			let error = member
				.say("not admitted")
				.await
				.err()
				.expect("quota refuses before broadcast");
			let reason = error.to_string();
			let advice = rooms_application::failure::Failure::parse(&reason)
				.unwrap()
				.retry_advice()
				.unwrap();
			assert_eq!(advice.class, rooms_application::admission::Class::Message);
			let other_runtime = super::runtime().await;
			let other = Client::new(
				other_runtime.connect(&locator, Default::default()).await.unwrap(),
				HostPlatform,
			);
			let other_directory = Directory::fetch(other.clone()).await.unwrap();
			let other_entrance = other_directory.enter("Admission").await.unwrap();
			let (healthy, _healthy_messages) =
				Room::subscribe(other.clone(), other_entrance, "Bob", Default::default())
					.await
					.unwrap();
			healthy.say("independent allowance").await.unwrap();
			member.leave().await.unwrap();
			healthy.leave().await.unwrap();
			closing_tolerated(first.session().close(PendingWork::Cancel).await);
			closing_tolerated(other.session().close(PendingWork::Cancel).await);
			running.stop.send(()).unwrap();
			running.task.await.unwrap().unwrap();
			runtime.close(PendingWork::Cancel).await.unwrap();
			other_runtime.close(PendingWork::Cancel).await.unwrap();
		})
		.await;
}

#[tokio::test]
async fn ordinary_crowded_room_cost_sample() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let temp = Temp::new();
			let running = start(temp.0.clone(), tcp()).await;
			let mut runtimes = Vec::new();
			let mut members = Vec::new();
			let mut messages = Vec::new();
			let locator = glowcap::parse_locator(&running.location).unwrap();
			for index in 0..8 {
				let runtime = runtime().await;
				let client = Client::new(
					runtime.connect(&locator, Default::default()).await.unwrap(),
					HostPlatform,
				);
				let directory = Directory::fetch(client.clone()).await.unwrap();
				let entrance = if index == 0 {
					directory.open("Cost").await.unwrap()
				} else {
					directory.enter("Cost").await.unwrap()
				};
				let (member, incoming) = Room::subscribe(client, entrance, &format!("peer{index}"), Default::default())
					.await
					.unwrap();
				members.push(member);
				messages.push(incoming);
				runtimes.push(runtime);
			}
			let start = std::time::Instant::now();
			for member in &members {
				for _ in 0..8 {
					member.say("A small ordinary message").await.unwrap();
				}
			}
			println!(
				"native cost: 64 posts, 8 recipients, average round-trip us={}",
				start.elapsed().as_micros() / 64
			);
			for member in members {
				member.leave().await.unwrap();
			}
			drop(messages);
			running.stop.send(()).unwrap();
			running.task.await.unwrap().unwrap();
			for runtime in runtimes {
				runtime.close(PendingWork::Cancel).await.unwrap();
			}
		})
		.await;
}

/// The full timing case runs once outside the short default process gate.
#[tokio::test]
#[ignore = "live thirty-second churn acceptance; run explicitly with a 45 second deadline"]
async fn live_thirty_second_proved_reconnect_debt() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let temp = Temp::new();
			let running = start(temp.0.clone(), Transport::Iroh(iroh::Reachability::Direct)).await;
			let runtime = Runtime::open(RuntimeConfig::providers([iroh::provider(iroh::Config::new(
				iroh::Reachability::Direct,
			))]))
			.await
			.unwrap();
			let locator = glowcap::parse_locator(&running.location).unwrap();
			let healthy = Runtime::open(RuntimeConfig::providers([iroh::provider(iroh::Config::new(
				iroh::Reachability::Direct,
			))]))
			.await
			.unwrap();
			let healthy_session = healthy.connect(&locator, Default::default()).await.unwrap();
			let healthy_directory = Directory::fetch(Client::new(healthy_session.borrowed(), HostPlatform))
				.await
				.unwrap();
			let healthy_client = Client::new(healthy_session.borrowed(), HostPlatform);
			let entrance = healthy_directory.open("Churn").await.unwrap();
			let (healthy_member, mut healthy_messages) = Room::subscribe(healthy_client, entrance, "Healthy", Default::default()).await.unwrap();
			let start = tokio::time::Instant::now();
			let mut admitted = 0;
			let mut refused = 0;
			let mut joined = 0;
			for second in 0..=30 {
				tokio::time::sleep_until(start + Duration::from_secs(second)).await;
				let session = runtime.connect(&locator, Default::default()).await.unwrap();
				let directory = Directory::fetch(Client::new(session.borrowed(), HostPlatform))
					.await
					.unwrap();
				match directory.list().await {
					Ok(_) => {
						admitted += 1;
						let entrance = directory.enter("Churn").await.unwrap();
						match Room::subscribe(Client::new(session.borrowed(), HostPlatform), entrance, "Churner", Default::default()).await {
							Ok((member, _messages)) => {
								joined += 1;
								use rooms_application::room::inbox::metadata::Presence;
								loop {
									if matches!(super::rooms::next_presence(&mut healthy_messages).await, Presence::Join { name } if name == "Churner") { break; }
								}
								closing_tolerated(session.close(PendingWork::Cancel).await);
								loop {
									if matches!(super::rooms::next_presence(&mut healthy_messages).await, Presence::Offline { names } if names.iter().any(|name| name == "Churner")) { break; }
								}
								drop(member);
							}
							Err(error) => assert!(error.to_string().contains("rate-limited:"), "{error}"),
						}
					},
					Err(error) => {
						assert!(error.to_string().contains("rate-limited:"), "{error}");
						refused += 1;
					}
				}
				healthy_directory.list().await.unwrap();
				healthy_member.say("healthy progress").await.unwrap();
				assert_eq!(super::rooms::next_said(&mut healthy_messages).await.text, "healthy progress");
				closing_tolerated(session.close(PendingWork::Cancel).await);
			}
			assert!(
				(8..=9).contains(&admitted),
				"starts must obey six burst plus elapsed refill: {admitted}"
			);
			assert!(refused > 0);
			assert!((4..=7).contains(&joined), "room joins obey their independent budget: {joined}");
			println!("live churn: admitted={admitted}, refused={refused}, room joins={joined}, healthy posts=31");
			healthy_member.leave().await.unwrap();
			closing_tolerated(healthy_session.close(PendingWork::Cancel).await);
			running.stop.send(()).unwrap();
			running.task.await.unwrap().unwrap();
			runtime.close(PendingWork::Cancel).await.unwrap();
			healthy.close(PendingWork::Cancel).await.unwrap();
		})
		.await;
}
