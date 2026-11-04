//! Internal vow discards cannot transfer inaccessible retains to manual callers.
use super::support::*;

#[derive(Clone, Copy, Debug)]
enum Discard {
	Observed,
	Abandon,
	Evict,
	CancelledWaiter,
	DeliveredWaiter,
}

#[tokio::test]
async fn unexposed_raw_outcomes_retire_without_changing_manual_observations() {
	LocalSet::new()
		.run_until(async {
			let mut failures = Vec::new();
			for profile in [crate::HostProfile::Interop, crate::HostProfile::Glowcap] {
				for automatic in [true, false] {
					let options = crate::HostOptions::with_profile(profile);
					let server_host = Host::with_options(options).unwrap();
					let client_host = Host::with_options(options).unwrap();
					let server = listen_with_host("127.0.0.1:0", server_host.clone()).await.unwrap();
					let locator = server.locator().unwrap();
					let (client, accepted) =
						tokio::join!(connect_with_host(&locator, client_host.clone()), server.accept());
					let client = client.unwrap();
					let accepted = accepted.unwrap();
					let child = accepted.spawn_owned(|_, _| Ok(Argument::Void)).unwrap();
					accepted
						.publish("raw-custody", move |verb, _| {
							Ok(match verb {
								Some("barrier") => Argument::Void,
								Some("anchor") => (&child).into(),
								_ => Argument::List(vec![
									(&child).into(),
									Argument::Tagged {
										tag: "opaque".into(),
										value: vec![(&child).into()],
									},
								]),
							})
						})
						.unwrap();
					let serving = tokio::task::spawn_local(accepted.serve());
					let target = client.fetch("raw-custody").await.unwrap();
					client_host.set_release_on_drop(automatic).unwrap();
					let host = &client.shared.host;
					let mut synthetic = u64::MAX;
					for case in [
						Discard::Observed,
						Discard::Abandon,
						Discard::Evict,
						Discard::CancelledWaiter,
						Discard::DeliveredWaiter,
					] {
						let Argument::Reference(anchor) = client
							.send(&target, "anchor", &[])
							.await
							.unwrap_or_else(|error| panic!("anchor {profile:?}/{automatic}/{case:?}: {error:?}"))
						else {
							panic!("expected anchor");
						};
						let id = anchor.id();
						let pending = client.send(&target, "compound", &[]);
						let vow = pending.vow().unwrap();
						match case {
							Discard::Observed => drop(pending.await.unwrap()),
							Discard::Abandon => {
								client.send(&target, "barrier", &[]).await.unwrap();
								drop(pending);
							}
							Discard::Evict => {
								client.send(&target, "barrier", &[]).await.unwrap();
								// Only FIFO pressure is synthetic; the evicted value
								// is the native reply with its real application retains.
								for _ in 0..=crate::abi_constants::BINDING_UNOBSERVED_OUTCOME_CAP {
									host.vow_minted(synthetic, Some(&client.shared));
									host.settle_vow(synthetic, Ok(Argument::Void));
									synthetic -= 1;
								}
								drop(pending);
							}
							Discard::CancelledWaiter | Discard::DeliveredWaiter => {
								// await_vow registers synchronously. Keep the public
								// handle alive to isolate receiver cleanup from abandon.
								let waiting = host.await_vow(vow);
								if matches!(case, Discard::CancelledWaiter) {
									drop(waiting);
									client.send(&target, "barrier", &[]).await.unwrap();
								} else {
									client.send(&target, "barrier", &[]).await.unwrap();
									drop(waiting);
								}
								drop(pending);
							}
						}
						client.shared.drain_gc().unwrap();
						// Vow retirement can enqueue capability retirement after
						// this drain's capability phase. Advance that queue before probing.
						client.send(&target, "barrier", &[]).await.unwrap();
						client.shared.drain_gc().unwrap();
						client.release(anchor).unwrap();
						let mut retained = 0;
						for _ in 0..3 {
							match client.release(Ref::bare_id(id)) {
								Err(error) => {
									assert_eq!(error.kind(), ErrorKind::NotFound);
									break;
								}
								Ok(()) => retained += 1,
							}
						}
						let expected = if matches!(case, Discard::Observed) && !automatic {
							2
						} else {
							0
						};
						if retained != expected {
							failures.push((profile, automatic, case, retained, expected));
						}
					}
					client.release(target).unwrap();
					client.close(crate::PendingWork::Cancel).await.unwrap();
					server.close().await.unwrap();
					serving.await.unwrap().unwrap();
				}
			}
			assert!(
				failures.is_empty(),
				"raw reply custody (retained, expected): {failures:?}"
			);
		})
		.await;
}
