use super::*;
use glowcap::Argument;
use rooms_runtime::rooms::operations::Operations;
mod fixture;
mod platform;
mod room_cancellation;
use fixture::Fixture;
use platform::ControlledPlatform;

async fn deadline(work: impl std::future::Future<Output = ()>) {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(10), work).await.unwrap();
		})
		.await;
}

#[tokio::test]
async fn expired_operations_retry_does_not_keep_waking_during_fetch() {
	deadline(async {
		let fixture = Fixture::new("timer").await;
		let _published = fixture
			.arrival
			.session
			.publish("missing", |_, _| Ok(Argument::Void))
			.unwrap();
		fixture.platform.timeout_next();
		fixture.operations.settle(&fixture.commands, &fixture.runtime).await;
		assert!(fixture.operations.next_retry().is_some());
		fixture.platform.advance(Duration::from_secs(2));
		fixture.operations.reconcile(&fixture.commands, &fixture.runtime);
		assert!(
			fixture.operations.next_retry().is_none(),
			"a running fetch must not leave an expired wakeup"
		);
		fixture.operations.settle(&fixture.commands, &fixture.runtime).await;
		assert!(fixture.operations.issues().is_empty());

		fixture.close().await;
	})
	.await;
}

#[tokio::test]
async fn late_operations_refusal_cannot_overwrite_a_success() {
	deadline(async {
		let fixture = Fixture::new("overlap").await;
		let (reached, resume) = fixture.platform.pause_next();
		fixture.operations.reconcile(&fixture.commands, &fixture.runtime);
		reached.await.unwrap();
		let _published = fixture
			.arrival
			.session
			.publish("missing", |_, _| Ok(Argument::Void))
			.unwrap();
		fixture
			.operations
			.call(
				&fixture.commands,
				&fixture.runtime,
				"listeners",
				&fixture.id,
				"test",
				&[],
			)
			.await
			.unwrap();
		resume.send(()).unwrap();
		fixture.operations.settle(&fixture.commands, &fixture.runtime).await;
		assert!(
			fixture.operations.issues().is_empty(),
			"a late refusal must not replace a held capability's success"
		);
		assert!(fixture.operations.next_retry().is_none());

		fixture.close().await;
	})
	.await;
}

#[tokio::test]
async fn obsolete_connection_refusal_cannot_stop_a_replacement_connection() {
	deadline(async {
		let mut fixture = Fixture::new("reconnect").await;
		let (reached, resume) = fixture.platform.pause_next();
		fixture.operations.reconcile(&fixture.commands, &fixture.runtime);
		reached.await.unwrap();
		fixture.arrival.session.close(PendingWork::Cancel).await.unwrap();
		let replacement = fixture.arrivals.recv().await.unwrap();
		replacement.ack().await;
		fixture.connected().await;
		let _published = replacement
			.session
			.publish("missing", |_, _| Ok(Argument::Void))
			.unwrap();
		resume.send(()).unwrap();
		fixture.operations.settle(&fixture.commands, &fixture.runtime).await;
		assert!(
			fixture.operations.issues().is_empty(),
			"a retired connection cannot record a refusal for its replacement"
		);
		fixture.operations.settle(&fixture.commands, &fixture.runtime).await;
		fixture
			.operations
			.call(
				&fixture.commands,
				&fixture.runtime,
				"listeners",
				&fixture.id,
				"test",
				&[],
			)
			.await
			.unwrap();

		fixture.close().await;
	})
	.await;
}

#[tokio::test]
async fn expired_peering_retry_does_not_keep_waking_during_fetch() {
	deadline(async {
		let fixture = Fixture::new("peering").await;
		use rooms_runtime::{
			rooms::{RoomRuntime, peering::Peering},
			session::bridge_secrets::BridgeSecrets,
		};
		command(
			&fixture.commands,
			"peering",
			Command::ReplaceOperationsCapabilities,
			vec![
				json!([{"capability":"peering","scope":fixture.id,"swiss":"missing"}])
					.to_string()
					.into(),
			],
		)
		.await;
		let _published = fixture
			.arrival
			.session
			.publish("missing", |_, _| Ok(Argument::Void))
			.unwrap();
		let bridge_secrets = BridgeSecrets::open(rooms_runtime::documents::VolatileDocument::new(
			rooms_application::documents::SessionDocument::BridgeSecrets,
		))
		.await
		.unwrap();
		let (rooms, _worker, _events) = RoomRuntime::open(
			fixture.platform.clone(),
			rooms_platform::OsEntropy,
			fixture.runtime.clone(),
			fixture.commands.clone(),
			bridge_secrets,
			None,
		)
		.unwrap();
		let peering = Peering::new(fixture.platform.clone());
		let mut ended = peering.changes();
		fixture.platform.timeout_next();
		peering.reconcile(&fixture.commands, &fixture.runtime, &rooms);
		ended.changed().await.unwrap();
		assert!(peering.next_retry().is_some());
		fixture.platform.advance(Duration::from_secs(2));
		peering.reconcile(&fixture.commands, &fixture.runtime, &rooms);
		assert!(
			peering.next_retry().is_none(),
			"peering also consumes its expired wakeup"
		);
		ended.changed().await.unwrap();
		assert!(peering.next_retry().is_none());
		peering.stop();

		fixture.close().await;
	})
	.await;
}

#[tokio::test]
async fn refused_operations_wait_for_new_credentials() {
	deadline(async {
		let fixture = Fixture::new("refusal").await;
		fixture.operations.settle(&fixture.commands, &fixture.runtime).await;
		assert!(
			fixture.operations.next_retry().is_none(),
			"an unknown credential cannot become valid by waiting"
		);
		assert!(fixture.operations.issues()[0].1.contains("Automatic retries stopped"));
		// Even if the peer later publishes the old name, unrelated reconciliation
		// must not redeem a credential whose automatic retries were stopped.
		let _old = fixture
			.arrival
			.session
			.publish("missing", |_, _| Ok(Argument::Void))
			.unwrap();
		fixture.platform.advance(Duration::from_secs(2));
		fixture.operations.settle(&fixture.commands, &fixture.runtime).await;
		assert_eq!(fixture.operations.issues().len(), 1);
		let _new = fixture
			.arrival
			.session
			.publish("replacement", |_, _| Ok(Argument::Void))
			.unwrap();
		command(
			&fixture.commands,
			"replace",
			Command::ReplaceOperationsCapabilities,
			vec![
				json!([{"capability":"listeners","scope":fixture.id,"swiss":"replacement"}])
					.to_string()
					.into(),
			],
		)
		.await;
		fixture.operations.settle(&fixture.commands, &fixture.runtime).await;
		assert!(fixture.operations.issues().is_empty());
		assert!(fixture.operations.next_retry().is_none());
		fixture
			.operations
			.call(
				&fixture.commands,
				&fixture.runtime,
				"listeners",
				&fixture.id,
				"test",
				&[],
			)
			.await
			.unwrap();

		fixture.close().await;
	})
	.await;
}
