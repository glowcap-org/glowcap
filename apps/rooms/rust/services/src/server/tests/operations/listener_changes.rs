//! Concurrent calls and a refused write exercise the actual operator path.
use super::{Asked, Temp, int, list, pair, rows, runtime, seat, start_with, tcp};
use glowcap::{Argument, ConnectOptions, PendingWork, TRANSPORT_KEYED_RELAY, TRANSPORT_KEYED_TCP, TRANSPORT_NOISE_TCP};
use rooms_application::server::operations::document::Document;
use std::time::Duration;

#[tokio::test]
async fn listener_changes_serialize_and_failed_forgetting_preserves_intent() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(30), async {
				let temp = Temp::new();
				let state = temp.0.join("state");
				let running = start_with(
					state.clone(),
					tcp(),
					Asked {
						admin_listeners: true,
						..Default::default()
					},
				)
				.await;
				let runtime = runtime().await;
				let session = runtime
					.connect(
						&glowcap::parse_locator(&running.location).unwrap(),
						ConnectOptions::default(),
					)
					.await
					.unwrap()
					.with_gc();
				let admin = session.fetch(&running.capabilities[0].swiss).await.unwrap();
				// A stalled relay handshake holds its own preparation, never the
				// document writer or another transport's lifecycle.
				let relay = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
				let route = format!("ws://{}/", relay.local_addr().unwrap());
				let relay_args = [
					Argument::from(TRANSPORT_KEYED_RELAY),
					Argument::List(vec![pair("relay", route.into())]),
				];
				let (stalled, ()) = tokio::join!(session.send(&admin, "up", &relay_args), async {
					let (socket, _) = relay.accept().await.unwrap();
					tokio::time::timeout(Duration::from_secs(2), async {
						session
							.send(&admin, "up", &[Argument::from(TRANSPORT_NOISE_TCP)])
							.await
							.unwrap();
						let id = int(seat(&list(&session, &admin).await, TRANSPORT_NOISE_TCP), 6);
						session.send(&admin, "down", &[Argument::Integer(id)]).await.unwrap();
					})
					.await
					.expect("a slow relay must not park an independent listener change");
					drop(socket);
				});
				assert!(stalled.is_err());
				// Both calls arrive while the first socket is opening. Exactly one
				// may acquire this transport, regardless of completion order.
				let args = [Argument::from(TRANSPORT_KEYED_TCP)];
				let (one, two) = tokio::join!(session.send(&admin, "up", &args), session.send(&admin, "up", &args));
				assert_ne!(one.is_ok(), two.is_ok());
				let refused = if let Err(error) = one { error } else { two.unwrap_err() };
				assert!(refused.to_string().contains("listener-transport-held"));
				// Different transports must both survive in the same document.
				let first_id = int(seat(&list(&session, &admin).await, TRANSPORT_KEYED_TCP), 6);
				session
					.send(&admin, "down", &[Argument::Integer(first_id)])
					.await
					.unwrap();
				let noise_args = [Argument::from(TRANSPORT_NOISE_TCP)];
				let (keyed, noise) = tokio::join!(
					session.send(&admin, "up", &args),
					session.send(&admin, "up", &noise_args)
				);
				keyed.unwrap();
				noise.unwrap();
				let read =
					|| Document::decode(&std::fs::read_to_string(state.join("operations.json")).unwrap()).unwrap();
				assert_eq!(read().listeners.len(), 2);
				let seats = list(&session, &admin).await;
				let id = int(seat(&seats, TRANSPORT_KEYED_TCP), 6);
				// Move the leased directory out of its named path. Staging now
				// fails before replacement, without depending on user permissions.
				let parked = temp.0.join("parked");
				std::fs::rename(&state, &parked).unwrap();
				let result = session.send(&admin, "down", &[Argument::Integer(id)]).await;
				std::fs::rename(&parked, &state).unwrap();
				assert!(
					result
						.unwrap_err()
						.to_string()
						.contains("keeping the operations document failed")
				);
				assert_eq!(int(seat(&list(&session, &admin).await, TRANSPORT_KEYED_TCP), 6), id);
				assert_eq!(read().listeners.len(), 2);
				// Retrying proves the failed write did not forget the in-memory
				// intent: the successful retry must actually remove it from disk.
				session.send(&admin, "down", &[Argument::Integer(id)]).await.unwrap();
				assert_eq!(read().listeners.len(), 1);
				assert_eq!(
					int(
						seat(
							&rows(&session.send(&admin, "list", &[]).await.unwrap()),
							TRANSPORT_KEYED_TCP
						),
						6
					),
					0
				);
				session.close(PendingWork::Cancel).await.unwrap();
				running.stop.send(()).unwrap();
				running.task.await.unwrap().unwrap();
				runtime.close(PendingWork::Cancel).await.unwrap();
			})
			.await
			.expect("listener mutation scenario deadline");
		})
		.await;
}
