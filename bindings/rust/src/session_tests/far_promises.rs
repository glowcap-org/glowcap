//! Far promise breaking and the partner's retained abort.

use super::support::*;

// Breaking far promises fails the work still waiting on the partner and keeps
// the connection usable for the next send. The break needs an embedder-driven
// session, so the pair runs over an in-memory byte channel.
#[tokio::test]
async fn breaking_far_promises_fails_pending_sends_and_keeps_the_session() {
	LocalSet::new()
		.run_until(async {
			let exporter = Host::from_seed([73; 32]).unwrap();
			let dialer = Host::from_seed([74; 32]).unwrap();
			let locator = crate::Locator::bare(crate::abi_constants::TRANSPORT_TCP, "127.0.0.1:9012");
			exporter.set_advertised_locator(&locator).unwrap();
			let (parked_tx, mut parked_rx) = tokio::sync::mpsc::channel(1);
			let worker = exporter.clone();
			exporter
				.publish("svc", move || {
					let (worker, parked_tx) = (worker.clone(), parked_tx.clone());
					Box::new(move |verb, _args| {
						if verb == Some("hang") {
							// The parked resolver keeps the answer pending.
							let resolver = worker.defer_turn().map_err(|e| e.to_string())?;
							parked_tx.try_send(resolver).map_err(|e| e.to_string())?;
							return Ok(Argument::Void);
						}
						Ok(Argument::Symbol("alive".into()))
					})
				})
				.unwrap();
			let (left, right) = tokio::io::duplex(4096);
			let budget = Some(std::time::Duration::from_secs(5));
			let (dialed, accepted) = tokio::join!(
				crate::Session::dial_over(&dialer, &locator, left, budget),
				crate::Session::accept_over(&exporter, "tcp", "127.0.0.1:9012", "127.0.0.1:9012", right, budget)
			);
			let (client, _accepted) = (dialed.unwrap(), accepted.unwrap());
			let svc = client.fetch("svc").await.unwrap();
			let pending = client.send(&svc, "hang", &[]);
			let resolver = parked_rx.recv().await.unwrap();
			client.break_far_promises("gave up waiting").unwrap();
			let error = pending.await.unwrap_err();
			assert_eq!(error.kind(), ErrorKind::Broken);
			assert!(error.to_string().contains("gave up waiting"), "{error}");
			assert_eq!(
				client.send(&svc, "ping", &[]).await.unwrap(),
				Argument::Symbol("alive".into())
			);
			drop(resolver);
			exporter.close(crate::PendingWork::Cancel).await.unwrap();
			dialer.close(crate::PendingWork::Cancel).await.unwrap();
		})
		.await;
}

// A session a driver loop owns refuses the break before any effect, and the
// connection keeps answering.
#[tokio::test]
async fn a_driver_owned_session_refuses_to_break_far_promises() {
	LocalSet::new()
		.run_until(async {
			let server = listen("127.0.0.1:0").await.unwrap();
			let port = server.port().unwrap();
			let (ready_tx, ready_rx) = oneshot::channel::<()>();
			let serving = tokio::task::spawn_local(async move {
				let session = server.accept().await.unwrap();
				session
					.publish("svc", |_verb, _args| Ok(Argument::Symbol("alive".into())))
					.unwrap();
				ready_tx.send(()).unwrap();
				session.serve().await.unwrap();
			});
			let session = connect(&crate::tcp::locator("127.0.0.1", port), ConnectOptions::default())
				.await
				.unwrap();
			ready_rx.await.unwrap();
			let svc = session.fetch("svc").await.unwrap();
			let refused = session.break_far_promises("not mine to break").unwrap_err();
			assert_eq!(refused.kind(), ErrorKind::InvalidArgument, "{refused:?}");
			assert_eq!(
				session.send(&svc, "ping", &[]).await.unwrap(),
				Argument::Symbol("alive".into())
			);
			session.close(crate::PendingWork::Cancel).await.unwrap();
			serving.await.unwrap();
		})
		.await;
}

// The partner's close arrives as an `op:abort` of kind NormalShutdown, and the
// receiving side keeps it after its own release. The closing side received none.
#[tokio::test]
async fn the_partner_abort_outlives_the_session_that_received_it() {
	LocalSet::new()
		.run_until(async {
			let exporter = Host::from_seed([75; 32]).unwrap();
			let dialer = Host::from_seed([76; 32]).unwrap();
			let locator = crate::Locator::bare(crate::abi_constants::TRANSPORT_TCP, "127.0.0.1:9013");
			exporter.set_advertised_locator(&locator).unwrap();
			let (left, right) = tokio::io::duplex(4096);
			let budget = Some(std::time::Duration::from_secs(5));
			let (dialed, accepted) = tokio::join!(
				crate::Session::dial_over(&dialer, &locator, left, budget),
				crate::Session::accept_over(&exporter, "tcp", "127.0.0.1:9013", "127.0.0.1:9013", right, budget)
			);
			let (client, accepted) = (dialed.unwrap(), accepted.unwrap());
			assert_eq!(accepted.partner_abort().unwrap(), None);
			client.close(crate::PendingWork::Cancel).await.unwrap();
			// tolerant: the partner's close may end this side with a terminal cause.
			let _ = accepted.closed().await;
			assert!(accepted.shared.released.get(), "the receiving side released its handle");
			assert_eq!(
				accepted.partner_abort().unwrap(),
				Some(crate::PartnerAbort {
					kind: "NormalShutdown".into(),
					message: "session closing".into()
				})
			);
			assert_eq!(
				client.partner_abort().unwrap(),
				None,
				"the closing side received no abort"
			);
			exporter.close(crate::PendingWork::Cancel).await.unwrap();
			dialer.close(crate::PendingWork::Cancel).await.unwrap();
		})
		.await;
}
