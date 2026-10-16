//! Codec-value scenarios: the rare marshal arms carried end to end.

use super::support::*;

// The codec selector end-to-end on the session tier: two Cap'n Proto
// nodes complete the keyed handshake and carry a deliver whose arguments
// round-trip through the capnp codec: a big integer past int64 and a
// Keyword included, so the two rare marshal arms are witnessed alongside
// the codec.
#[tokio::test]
async fn capnp_hosts_handshake_and_round_trip_big_integer_and_keyword() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let next_capnp_host = || {
				Host::with_options(crate::HostOptions {
					codec: Codec::Capnp,
					captp_version: crate::CaptpVersion::Next,
					features: crate::FeatureSet::FULL,
					..Default::default()
				})
				.unwrap()
			};
			let server = listen_with_host("127.0.0.1:0", next_capnp_host()).await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));
			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				assert_eq!(
					session.profile().unwrap(),
					crate::SessionProfile {
						captp_version: crate::CaptpVersion::Next,
						codec: Codec::Capnp,
						features: crate::FeatureSet::from_bits(
							crate::FeatureSet::FULL.bits() & !crate::FeatureSet::UNTAG.bits()
						)
						.unwrap(),
					}
				);
				session
					.publish("echo", |_verb, args| Ok(Argument::List(args.to_vec())))
					.unwrap();
				ready_tx.send(()).unwrap();
				session.serve().await.unwrap();
			});

			let session = connect_with_host(
				&crate::tcp::locator(&addr.ip().to_string(), addr.port()),
				next_capnp_host(),
			)
			.await
			.unwrap();
			assert_eq!(
				session.profile().unwrap(),
				crate::SessionProfile {
					captp_version: crate::CaptpVersion::Next,
					codec: Codec::Capnp,
					features: crate::FeatureSet::from_bits(
						crate::FeatureSet::FULL.bits() & !crate::FeatureSet::UNTAG.bits()
					)
					.unwrap(),
				}
			);
			ready_rx.await.unwrap();
			let echo = session.fetch("echo").await.unwrap();
			// 2^80: past int64, so it must ride the ARG_BIG_INTEGER arm.
			let big = Argument::BigInteger {
				negative: false,
				digits: "1208925819614629174706176".to_string(),
			};
			let args = vec![
				big.clone(),
				Argument::Keyword("prio".into()),
				Argument::Bytes(b"hi".to_vec()),
				Argument::Error("failure is a value".into()),
				Argument::Struct(vec![
					("count".into(), Argument::Integer(7)),
					("name".into(), Argument::String("widget".into())),
				]),
			];
			let reply = session.send(&echo, "roundtrip", &args).await.unwrap();
			assert_eq!(reply, Argument::List(args));
			session.close(crate::PendingWork::Cancel).await.unwrap();
			host.await.unwrap();
		})
		.await;
}

// A typed integer run (ADR-0247) is sent as one leaf and the peer receives the
// same OCapN value as a List of Integers.
#[tokio::test]
async fn integers_run_arrives_as_a_list_of_integers() {
	let local = LocalSet::new();
	local
		.run_until(async {
			let server = listen("127.0.0.1:0").await.unwrap();
			let addr = std::net::SocketAddr::from(([127, 0, 0, 1], server.port().unwrap()));
			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let host = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				session
					.publish("sink", |_verb, args| {
						let expected = Argument::List(vec![7.into(), (-8).into(), 9.into()]);
						if args == [expected] {
							Ok(Argument::Symbol("ok".into()))
						} else {
							Err(format!("unexpected arguments: {args:?}"))
						}
					})
					.unwrap();
				ready_tx.send(()).unwrap();
				session.serve().await.unwrap();
			});

			let locator = crate::tcp::locator(&addr.ip().to_string(), addr.port());
			let session = connect(&locator, ConnectOptions::default()).await.unwrap();
			ready_rx.await.unwrap();
			let sink = session.fetch("sink").await.unwrap();
			let reply = session
				.send(&sink, "take", &[Argument::Integers(vec![7, -8, 9])])
				.await
				.unwrap();
			assert_eq!(reply, Argument::Symbol("ok".into()));
			session.close(crate::PendingWork::Cancel).await.unwrap();
			host.await.unwrap();
		})
		.await;
}
