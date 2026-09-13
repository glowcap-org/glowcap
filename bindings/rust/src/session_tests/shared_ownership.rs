//! Host-selected connections have explicit shared owners and non-owning views.
use super::support::*;
use crate::{CaptpVersion, PendingWork, Runtime};
use std::time::Duration;

#[tokio::test]
async fn host_first_network_work_reuses_exporters_and_releases_owned_occurrences() {
	LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(20), async {
				for (fetch_first, byte_fed) in [(false, false), (true, false), (false, true), (true, true)] {
					let server = listen("127.0.0.1:0").await.unwrap();
					let locator = tcp::locator("127.0.0.1", server.port().unwrap());
					let serving = tokio::task::spawn_local(async move {
						let session = server.accept().await.unwrap();
						session.publish("authority", |_, _| Ok("alive".into())).unwrap();
						session.serve().await.unwrap();
					});
					let config = if byte_fed {
						RuntimeConfig::connectors([crate::Connector::new(
							&[crate::TRANSPORT_TCP],
							|host, locator, _, _, timeout| {
								Box::pin(async move {
									let stream = tokio::net::TcpStream::connect(&locator.designator).await?;
									Session::dial_channel(&host, locator, crate::Channel::stream(stream), timeout, None)
										.await
								})
							},
						)
						.unwrap()])
					} else {
						RuntimeConfig::providers([tcp::provider(Default::default())])
					};
					let runtime = Runtime::open(config).await.unwrap();
					let host = runtime.host();
					let link = crate::format_sturdyref(&locator, b"authority", CaptpVersion::V1_0).unwrap();
					// There has been no explicit connect/listen on this Runtime.
					let first = if fetch_first {
						host.fetch_at(&locator, "authority").await.unwrap()
					} else {
						host.enliven_for_version(&link, CaptpVersion::V1_0).await.unwrap()
					};
					let owner = host.reference_session(&first).unwrap().unwrap();
					let view = owner.borrowed();
					let second = host.enliven_for_version(&link, CaptpVersion::V1_0).await.unwrap();
					assert_eq!(first, second);
					let another = host.reference_session(&second).unwrap().unwrap();
					assert!(owner.same_session(&another));
					drop(another);
					assert!(
						view.is_open(),
						"dropping an application handle condemned a Host-retained dial"
					);
					let another = host.reference_session(&second).unwrap().unwrap();
					another.relinquish(PendingWork::Cancel).await.unwrap();
					owner.borrowed().relinquish(PendingWork::Cancel).await.unwrap();
					assert!(view.is_open());
					let stale = Ref::bare_id(first.id());
					drop(first);
					owner.shared.drain_gc().unwrap();
					assert_eq!(view.send(&second, "probe", &[]).await.unwrap().as_str(), Some("alive"));
					drop(second);
					owner.shared.drain_gc().unwrap();
					assert!(
						view.send(&stale, "probe", &[]).await.is_err(),
						"Host result leaked its retain"
					);
					let local = owner.spawn_owned(|_, _| Ok(Argument::Void)).unwrap();
					assert!(host.reference_session(&local).unwrap().is_none());
					drop(local);
					// Reacquire after the old application occurrences have retired.
					let fresh = host.enliven_for_version(&link, CaptpVersion::V1_0).await.unwrap();
					assert!(host.reference_session(&fresh).unwrap().unwrap().same_session(&owner));
					owner.relinquish(PendingWork::Cancel).await.unwrap();
					assert!(
						view.is_open(),
						"relinquishing an application handle closed a Host-retained dial"
					);
					view.close(PendingWork::Cancel).await.unwrap();
					assert!(!view.is_open(), "explicit close left a Host-retained dial open");
					assert!(view.send(&fresh, "probe", &[]).await.is_err());
					drop(fresh);
					runtime.close(PendingWork::Cancel).await.unwrap();
					serving.await.unwrap();
				}
			})
			.await
			.expect("shared session ownership deadline");
		})
		.await;
}
