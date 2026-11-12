//! Which TCP profiles a runtime registers decides which locators it dials.

use super::support::*;

// A runtime opened with only the noise profile registers no other TCP
// transport, so a plain tcp locator is refused before anything is dialed,
// while a noise-tcp locator connects.
#[tokio::test]
async fn a_noise_only_runtime_refuses_a_plain_tcp_locator() {
	LocalSet::new()
		.run_until(async {
			let plain = tcp::listen("127.0.0.1", 0, tcp::ListenOptions::default())
				.await
				.unwrap();
			let sealed = tcp::noise::listen("127.0.0.1", 0, tcp::ListenOptions::default())
				.await
				.unwrap();
			let runtime = crate::Runtime::open(RuntimeConfig::providers([tcp::provider(tcp::Config {
				profiles: tcp::Profiles::NOISE_TCP,
				..Default::default()
			})]))
			.await
			.unwrap();

			let refusal = runtime
				.connect(&plain.locator().unwrap(), ConnectOptions::default())
				.await
				.err()
				.expect("a noise-only runtime must refuse a plain tcp locator");
			assert_eq!(refusal.kind(), ErrorKind::InvalidArgument);
			assert_eq!(
				crate::RouteFailure::from_cause(refusal.cause()),
				Some(crate::RouteFailure::TransportUnavailable)
			);

			let locator = sealed.locator().unwrap();
			let (client, accepted) =
				tokio::join!(runtime.connect(&locator, ConnectOptions::default()), sealed.accept());
			let (client, accepted) = (client.unwrap(), accepted.unwrap());
			assert_eq!(client.transport_name().unwrap(), crate::TRANSPORT_NOISE_TCP);
			client.close(crate::PendingWork::Cancel).await.unwrap();
			accepted.close(crate::PendingWork::Cancel).await.unwrap();
			sealed.close().await.unwrap();
			plain.close().await.unwrap();
		})
		.await;
}

// A runtime opened with only the plain profile connects to a plain locator and
// refuses a noise-tcp locator, so a swapped profile pairing fails.
#[tokio::test]
async fn a_plain_only_runtime_connects_plain_and_refuses_a_sealed_locator() {
	LocalSet::new()
		.run_until(async {
			let plain = tcp::listen("127.0.0.1", 0, tcp::ListenOptions::default())
				.await
				.unwrap();
			let sealed = tcp::noise::listen("127.0.0.1", 0, tcp::ListenOptions::default())
				.await
				.unwrap();
			let runtime = crate::Runtime::open(RuntimeConfig::providers([tcp::provider(tcp::Config {
				profiles: tcp::Profiles::TCP,
				..Default::default()
			})]))
			.await
			.unwrap();

			let refusal = runtime
				.connect(&sealed.locator().unwrap(), ConnectOptions::default())
				.await
				.err()
				.expect("a plain-only runtime must refuse a noise-tcp locator");
			assert_eq!(refusal.kind(), ErrorKind::InvalidArgument);
			assert_eq!(
				crate::RouteFailure::from_cause(refusal.cause()),
				Some(crate::RouteFailure::TransportUnavailable)
			);

			let locator = plain.locator().unwrap();
			let (client, accepted) = tokio::join!(runtime.connect(&locator, ConnectOptions::default()), plain.accept());
			let (client, accepted) = (client.unwrap(), accepted.unwrap());
			assert_eq!(client.transport_name().unwrap(), crate::TRANSPORT_TCP);
			client.close(crate::PendingWork::Cancel).await.unwrap();
			accepted.close(crate::PendingWork::Cancel).await.unwrap();
			sealed.close().await.unwrap();
			plain.close().await.unwrap();
		})
		.await;
}

// A byte-fed runtime with no connector for a locator's transport reports the
// same typed cause as a driver runtime missing the provider.
#[tokio::test]
async fn a_byte_fed_runtime_without_the_connector_reports_the_typed_cause() {
	LocalSet::new()
		.run_until(async {
			let runtime = crate::Runtime::open(RuntimeConfig::connectors(Vec::<crate::Connector>::new()))
				.await
				.unwrap();
			let refusal = runtime
				.connect(&crate::tcp::locator("127.0.0.1", 1), ConnectOptions::default())
				.await
				.err()
				.expect("no connector for tcp");
			assert_eq!(refusal.kind(), ErrorKind::InvalidArgument);
			assert_eq!(
				crate::RouteFailure::from_cause(refusal.cause()),
				Some(crate::RouteFailure::TransportUnavailable)
			);
			runtime.close(crate::PendingWork::Cancel).await.unwrap();
		})
		.await;
}
