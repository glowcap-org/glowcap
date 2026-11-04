//! Reply occurrence custody is independent of the server's actor roots.
use super::support::*;

#[tokio::test]
async fn reply_occurrences_follow_the_raw_drop_policy() {
	check_reply_custody(false).await;
}

#[tokio::test]
async fn discarded_owned_reply_occurrences_retire_under_both_drop_policies() {
	check_reply_custody(true).await;
}

#[tokio::test]
async fn abandoned_owned_observations_retire_late_capability_replies() {
	use std::future::IntoFuture;
	LocalSet::new()
		.run_until(async {
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
					let deferred = Rc::new(std::cell::RefCell::new(None));
					let waiting = deferred.clone();
					let owner = server_host.clone();
					let returned = child.clone();
					accepted
						.publish("reply", move |verb, _| match verb {
							Some("defer") => {
								*waiting.borrow_mut() = Some(owner.defer_turn().unwrap());
								Ok(Argument::Void)
							}
							Some("barrier") => Ok(Argument::Void),
							_ => Ok((&returned).into()),
						})
						.unwrap();
					let serving = tokio::task::spawn_local(accepted.serve());
					let target = client.fetch("reply").await.unwrap();
					client_host.set_release_on_drop(automatic).unwrap();
					let Argument::Reference(anchor) = client.send(&target, "anchor", &[]).await.unwrap() else {
						panic!("expected anchor capability");
					};
					let id = anchor.id();
					let mut observation = client.send(&target, "defer", &[]).with_owned_outcome().into_future();
					std::future::poll_fn(|cx| {
						assert!(observation.as_mut().poll(cx).is_pending());
						std::task::Poll::Ready(())
					})
					.await;
					client.send(&target, "barrier", &[]).await.unwrap();
					drop(observation);
					client.shared.drain_gc().unwrap();
					deferred
						.borrow_mut()
						.take()
						.unwrap()
						.fulfill_value(&(&child).into())
						.unwrap();
					client.send(&target, "barrier", &[]).await.unwrap();
					client.shared.drain_gc().unwrap();
					client.release(anchor).unwrap();
					assert_eq!(
						client.release(Ref::bare_id(id)).unwrap_err().kind(),
						ErrorKind::NotFound
					);
					client.release(target).unwrap();
					client.close(crate::PendingWork::Cancel).await.unwrap();
					server.close().await.unwrap();
					serving.await.unwrap().unwrap();
				}
			}
		})
		.await;
}

async fn check_reply_custody(owned: bool) {
	let mut leaked = Vec::new();
	LocalSet::new()
		.run_until(async {
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
						.publish("reply", move |verb, _| {
							Ok(if verb == Some("barrier") {
								Argument::Void
							} else if verb == Some("compound") {
								Argument::List(vec![
									Argument::Bytes(vec![0, 1]),
									(&child).into(),
									Argument::Tagged {
										tag: "opaque".into(),
										value: vec![(&child).into()],
									},
								])
							} else {
								(&child).into()
							})
						})
						.unwrap();
					let serving = tokio::task::spawn_local(accepted.serve());
					let target = client.fetch("reply").await.unwrap();
					client_host.set_release_on_drop(automatic).unwrap();
					for compound in [false, true] {
						for settled in [false, true] {
							if settled && !owned {
								continue;
							}
							let pending = client.send(&target, if compound { "compound" } else { "scalar" }, &[]);
							if settled {
								client.send(&target, "barrier", &[]).await.unwrap();
							}
							let pending = if owned {
								pending.with_owned_outcome().with_owned_outcome()
							} else {
								pending
							};
							let reply = pending.await.unwrap();
							let reference = match &reply {
								Argument::Reference(reference) => reference,
								Argument::List(fields) => match &fields[1] {
									Argument::Reference(reference) => reference,
									_ => panic!("expected capability field"),
								},
								_ => panic!("expected capability reply"),
							};
							let id = reference.id();
							if !owned {
								assert_eq!(reference.guard().is_some(), automatic);
							}
							// Equal identities are independent occurrences. The
							// opaque nested occurrence must retire with the value.
							drop(reply);
							client.shared.drain_gc().unwrap();
							let released = client.release(Ref::bare_id(id));
							if automatic || owned {
								match released {
									Err(error) => assert_eq!(error.kind(), ErrorKind::NotFound),
									Ok(()) => {
										if compound {
											client.release(Ref::bare_id(id)).unwrap();
										}
										leaked.push((profile, automatic, compound, settled));
									}
								}
							} else {
								released.unwrap();
								if compound {
									client.release(Ref::bare_id(id)).unwrap();
								}
							}
						}
					}
					if owned {
						let reply = client.send(&target, "scalar", &[]).with_owned_outcome().await.unwrap();
						let Argument::Reference(result) = reply else {
							panic!("expected capability result");
						};
						let id = result.id();
						assert!(result.guard().is_some());
						assert_eq!(client.send(&result, "read", &[]).await.unwrap(), Argument::Void);
						drop(result);
						client.shared.drain_gc().unwrap();
						assert_eq!(
							client.release(Ref::bare_id(id)).unwrap_err().kind(),
							ErrorKind::NotFound
						);
					}
					client.release(target).unwrap();
					client.close(crate::PendingWork::Cancel).await.unwrap();
					server.close().await.unwrap();
					serving.await.unwrap().unwrap();
				}
			}
		})
		.await;
	assert!(
		leaked.is_empty(),
		"discarded consumer retains were still live: {leaked:?}"
	);
}
