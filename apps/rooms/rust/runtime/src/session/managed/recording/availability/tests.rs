//! A replaced archive's late end cannot settle the current selection.
use super::*;
use glowcap::{Host, PendingWork, Runtime, RuntimeConfig, tcp};
use std::{rc::Rc, time::Duration};

#[tokio::test]
async fn replacement_fences_late_exporter_end_and_local_selection_has_no_transport_wait() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let host = Host::from_seed([127; 32]).unwrap();
			let server = tcp::listen(
				"127.0.0.1",
				0,
				tcp::ListenOptions {
					identity: glowcap::ListenerIdentity::Host(host),
					..Default::default()
				},
			)
			.await
			.unwrap();
			let locator = tcp::locator("127.0.0.1", server.port().unwrap());
			let peer = tokio::task::spawn_local(async move {
				let accepted = server.accept().await.unwrap();
				accepted.serve().await.unwrap();
			});
			let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
				.await
				.unwrap();
			let session = runtime.connect(&locator, Default::default()).await.unwrap();
			let availability = Rc::new(Availability::default());
			let old = FieldKey::new(1.try_into().unwrap(), 1.try_into().unwrap());
			let replacement = FieldKey::new(1.try_into().unwrap(), 2.try_into().unwrap());
			availability.observe(Some(old), Some(session.borrowed()));
			let ending = tokio::task::spawn_local({
				let availability = availability.clone();
				async move { availability.ended().await }
			});
			tokio::task::yield_now().await;
			availability.observe(Some(replacement), Some(session.borrowed()));
			session.close(PendingWork::Cancel).await.unwrap();
			let ended = tokio::time::timeout(Duration::from_secs(2), ending)
				.await
				.unwrap()
				.unwrap();
			assert_eq!(ended, old);
			availability.reported(ended);
			assert_eq!(
				availability.ended().await,
				replacement,
				"late reporting cannot mark replacement settled"
			);
			availability.reported(replacement);
			availability.observe(Some(replacement), Some(session.borrowed()));
			assert!(
				tokio::time::timeout(Duration::from_millis(10), availability.ended())
					.await
					.is_err(),
				"same exporter reports only once"
			);
			availability.observe(Some(old), None);
			assert!(
				tokio::time::timeout(Duration::from_millis(10), availability.ended())
					.await
					.is_err(),
				"a local archive has no transport lifetime"
			);
			availability.observe(None, None);
			assert!(availability.0.borrow().is_none());
			peer.await.unwrap();
		})
		.await;
}
