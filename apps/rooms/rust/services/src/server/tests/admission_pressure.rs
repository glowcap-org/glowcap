//! Native connection-cap fan-out with one active reader and bounded slow inboxes.
use super::*;
use rooms_glowcap::client::room::Room;

#[tokio::test]
#[ignore = "full host connection-cap acceptance; run alone under its 25 second deadline"]
async fn crowded_host_room_isolates_slow_inboxes_and_finishes_cleanup() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(25), async {
				let temp = Temp::new();
				// This load fixture creates the host connection cap in one
				// burst. Only its unproved-start envelope changes; message limits stay real.
				let settings = rooms_application::admission::Settings::parse(
					|key| (key == "admission-rates").then(|| "http-start=256/256".into()),
					8192,
					1,
				)
				.unwrap();
				let running = start_with_admission(temp.0.clone(), tcp(), Asked::default(), settings).await;
				let locator = glowcap::parse_locator(&running.location).unwrap();
				let mut runtimes = Vec::new();
				let mut members = Vec::new();
				let mut inboxes = Vec::new();
				for index in 0..rooms_platform::serving::CONNECTION_LIMIT {
					let runtime = runtime().await;
					let client = Client::new(
						runtime.connect(&locator, Default::default()).await.unwrap(),
						HostPlatform,
					);
					let directory = Directory::fetch(client.clone()).await.unwrap();
					let entrance = if index == 0 {
						directory.open("Crowded").await.unwrap()
					} else {
						directory.enter("Crowded").await.unwrap()
					};
					let (member, incoming) =
						Room::subscribe(client, entrance, &format!("peer{index}"), Default::default())
							.await
							.unwrap();
					members.push(member);
					inboxes.push(incoming);
					runtimes.push(runtime);
				}
				assert_eq!(members.len(), 128, "exercise the actual host serving cap");
				let mut healthy = inboxes.remove(0);
				let mut slow = inboxes.pop().unwrap();
				let mut readers = Vec::new();
				for mut inbox in inboxes {
					readers.push(tokio::task::spawn_local(async move {
						while inbox.next().await.unwrap().is_some() {}
					}));
				}
				let started = std::time::Instant::now();
				for member in &members[..members.len() - 1] {
					for _ in 0..3 {
						member.say("bounded fan-out").await.unwrap();
						assert_eq!(super::rooms::next_said(&mut healthy).await.text, "bounded fan-out");
					}
				}
				// The reader consumed every admitted line while unread peers
				// crossed their fixed backlog ceiling. They cannot park healthy callbacks.
				assert!(matches!(
					slow.next().await,
					Err(rooms_application::room::inbox::queue::Error::Overflow)
				));
				println!(
					"crowded host room: peers={}, posts=381, healthy round-trip us={}, slow inbox overflow bounded",
					members.len(),
					started.elapsed().as_micros() / 381
				);
				for member in members {
					member.leave().await.unwrap();
				}
				drop((healthy, slow));
				for reader in readers {
					reader.abort();
					let outcome = reader.await;
					assert!(outcome.is_ok() || outcome.unwrap_err().is_cancelled());
				}
				running.stop.send(()).unwrap();
				running.task.await.unwrap().unwrap();
				for runtime in runtimes {
					runtime.close(PendingWork::Cancel).await.unwrap();
				}
			})
			.await
			.expect("crowded room and teardown have bounded progress");
		})
		.await;
}
