//! Native frame lengths account for both requests and callbacks, including
//! method-name and correlation overhead, rather than estimating Syrup sizes.
use super::*;
use rooms_application::room::{inbox::metadata::Metadata, receipt};

#[tokio::test]
async fn locally_refused_posts_release_retained_capacity() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let temp = Temp::new();
			let running = start_with_admission(
				temp.0.clone(),
				tcp(),
				Asked::default(),
				rooms_application::admission::Settings::parse(
					|key| (key == "admission-scale").then(|| "100".into()),
					8192,
					1,
				)
				.unwrap(),
			)
			.await;
			let host = glowcap::Host::with_options(Default::default()).unwrap();
			host.set_session_limits(glowcap::SessionLimitOptions {
				max_frame_bytes: 4096,
				..Default::default()
			})
			.unwrap();
			let runtime =
				Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]).adopt_host(&host))
					.await
					.unwrap();
			let dial = glowcap::parse_locator(&running.location).unwrap();
			let client = Client::new(
				runtime.connect(&dial, ConnectOptions::default()).await.unwrap(),
				HostPlatform,
			);
			let directory = Directory::fetch(client.clone()).await.unwrap();
			let room = directory.open("Local admission").await.unwrap();
			let (member, mut messages) =
				rooms_glowcap::client::room::Room::subscribe(client.clone(), room, "Alice", Default::default())
					.await
					.unwrap();
			let text = "x".repeat(8192);
			for _ in 0..=rooms_application::room::inbox::queue::MAX_MESSAGES {
				let error = member.say(&text).await.err().expect("oversized send refused");
				assert!(
					matches!(&error, rooms_glowcap::client::Error::Unsent(error) if error.kind() == glowcap::ErrorKind::Session),
					"unsent bodies must not consume retained capacity: {error}"
				);
			}
			member.say("still usable").await.unwrap();
			loop {
				let message = messages.next().await.unwrap().unwrap();
				if matches!(message.metadata, Some(Metadata::Receipt(_))) {
					assert_eq!(message.text, "still usable");
					break;
				}
			}
			drop((member, messages, directory));
			closing_tolerated(client.session().close(PendingWork::Cancel).await);
			running.stop.send(()).unwrap();
			running.task.await.unwrap().unwrap();
			runtime.close(PendingWork::Cancel).await.unwrap();
		})
		.await;
}

#[tokio::test]
async fn retained_post_measures_request_and_callback_wire_bytes() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let temp = Temp::new();
			let running = start_with_admission(
				temp.0.clone(),
				tcp(),
				Asked::default(),
				rooms_application::admission::Settings::parse(
					|key| (key == "admission-scale").then(|| "100".into()),
					8192,
					1,
				)
				.unwrap(),
			)
			.await;
			let runtime = runtime().await;
			let dial = glowcap::parse_locator(&running.location).unwrap();
			let client = Client::new(
				runtime.connect(&dial, ConnectOptions::default()).await.unwrap(),
				HostPlatform,
			);
			let directory = Directory::fetch(client.clone()).await.unwrap();
			let room = directory.open("Measured").await.unwrap();
			let callbacks = Rc::new(RefCell::new(Vec::new()));
			let received = callbacks.clone();
			let inbox = client
				.session()
				.spawn_owned(move |verb, _| {
					received.borrow_mut().push(verb.to_owned());
					Ok(Argument::Void)
				})
				.unwrap();
			let subscribed = client
				.session()
				.send(&room, "subscribe", &["Alice".into(), inbox.into()])
				.await
				.unwrap();
			let Argument::Reference(seat) = &subscribed.as_list().unwrap()[0] else {
				panic!("membership capability")
			};
			let seat = seat.clone();
			let lengths = Rc::new(RefCell::new(Vec::new()));
			let measured = lengths.clone();
			let uninstall = glowcap::enable_trace(
				Box::new(move |event| {
					if !event.outbound
						&& let Some(len) = event.len
					{
						measured.borrow_mut().push((event.op.clone(), len));
					}
				}),
				None,
			);
			let mut lines = Vec::new();
			for size in [0, 1, 16, 256, 8192] {
				for request in [0, receipt::MAX_REQUEST] {
					let text = "x".repeat(size);
					let mut totals = Vec::new();
					for retained in [false, true] {
						let verb = if retained { receipt::POST } else { "post" };
						let args = if retained {
							vec![
								text.clone().into(),
								Argument::Boolean(false),
								Argument::Integer(request as i64),
							]
						} else {
							vec![text.clone().into()]
						};
						lengths.borrow_mut().clear();
						let before = callbacks.borrow().len();
						lines.push(client.session().send(&seat, verb, &args).await.unwrap());
						assert_eq!(
							callbacks.borrow().len(),
							before + 1,
							"the ordered callback precedes the reply"
						);
						assert_eq!(
							callbacks.borrow().last().unwrap(),
							if retained { receipt::TAG } else { "notify" }
						);
						assert_eq!(
							lengths.borrow().len(),
							2,
							"request and callback frames: {:?}",
							lengths.borrow()
						);
						totals.push(lengths.borrow().iter().map(|(_, len)| len).sum::<usize>());
					}
					assert!(
						totals[1] <= totals[0] + 24,
						"bounded request/callback bytes: text={size}, request={request}, ordinary={}, retained={}",
						totals[0],
						totals[1]
					);
					if request == 0 {
						assert!(
							totals[1] <= totals[0],
							"ordinary request identities save bytes even for empty text"
						);
					}
					if size >= 256 {
						assert!(
							totals[0] - totals[1] >= size - 24,
							"the retained path reduces request plus callback wire bytes"
						);
					}
				}
			}
			uninstall();
			// A rejected request is not retained until membership retirement. More
			// refusals than the entire pending budget must still leave room to post.
			let (member, mut messages) =
				rooms_glowcap::client::room::Room::subscribe(client.clone(), room.clone(), "Alice", Default::default())
					.await
					.unwrap();
			let invalid = serde_json::from_str("[\"https://example.org/not-in-the-message\"]").unwrap();
			for _ in 0..=rooms_application::room::inbox::queue::MAX_MESSAGES {
				let result = member.say_with_previews("no selected link", &invalid).await;
				assert!(
					matches!(result, Err(rooms_glowcap::client::Error::Binding(error)) if error.kind() == glowcap::ErrorKind::Broken),
					"the peer rejects each request, rather than local retained storage filling"
				);
			}
			// A caller may abandon either post verb after sending it. Rejection
			// cleanup belongs to the inbox, not that absent reply observer.
			for files in [false, true] {
				for _ in 0..=rooms_application::room::inbox::queue::MAX_MESSAGES {
					{
						let call = async {
							if files {
								member.post_files_with_previews("no selected link", &invalid).await
							} else {
								member.say_with_previews("no selected link", &invalid).await
							}
						};
						let mut call = std::pin::pin!(call);
						std::future::poll_fn(|cx| {
							assert!(
								std::future::Future::poll(call.as_mut(), cx).is_pending(),
								"admission must survive abandoned refusals"
							);
							std::task::Poll::Ready(())
						})
						.await;
					}
					// Same-session ordering drains the refusal before the next send.
					member.history().await.unwrap();
				}
			}
			member.say("still usable").await.unwrap();
			loop {
				let message = messages.next().await.unwrap().unwrap();
				if matches!(message.metadata, Some(Metadata::Receipt(_))) {
					assert_eq!(message.text, "still usable");
					break;
				}
			}
			drop((member, messages));
			drop((lines, seat, subscribed, room, directory));
			closing_tolerated(client.session().close(PendingWork::Cancel).await);
			running.stop.send(()).unwrap();
			running.task.await.unwrap().unwrap();
			runtime.close(PendingWork::Cancel).await.unwrap();
		})
		.await;
}
