//! Receipt admission leaves source custody with its explicit sender lease.
use super::*;
use rooms_glowcap::client::sources::{Reader, Source, Sources};
use std::{cell::RefCell, future::Future, pin::Pin};
struct Waiting(tokio::sync::watch::Sender<bool>);
impl Reader for Waiting {
	fn read(&self, _: usize, length: usize) -> Pin<Box<dyn Future<Output = std::result::Result<Vec<u8>, String>>>> {
		let mut ready = self.0.subscribe();
		Box::pin(async move {
			while !*ready.borrow_and_update() {
				ready.changed().await.map_err(|e| e.to_string())?;
			}
			Ok(vec![7; length])
		})
	}
}
#[cfg(all(test, not(target_arch = "wasm32")))]
#[tokio::test]
async fn receipt_admission_keeps_sender_sources_and_in_flight_reads_have_separate_custody() {
	run().await;
}
pub(super) async fn run() {
	run_local().await;
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(10_000, async {
				let owner = Host::from_seed([130; 32]).unwrap();
				let sender = Host::from_seed([131; 32]).unwrap();
				let incoming = Rc::new(RefCell::new(None::<Ref>));
				owner
					.publish("ingestion", {
						let incoming = incoming.clone();
						move || {
							let incoming = incoming.clone();
							Box::new(move |verb, args| {
								if verb != "admit" {
									return Err("unexpected ingestion request".into());
								}
								let rows: Vec<_> = rooms_glowcap::values(args).collect();
								let attachments = rooms_application::room::attachment::read_exact(&rows, 0)
									.map_err(|error| format!("{error:?}"))?;
								assert_eq!(attachments.len(), 1);
								*incoming.borrow_mut() = Some(attachments.into_iter().next().unwrap().blob);
								Ok("pending".into())
							})
						}
					})
					.unwrap();
				let locator = glowcap::Locator::bare("tcp", "127.0.0.1:9162");
				let (left, right) = tokio::io::duplex(8192);
				let budget = Some(std::time::Duration::from_secs(2));
				let (dialed, accepted) = tokio::join!(
					glowcap::Session::dial_over(&sender, &locator, left, budget),
					glowcap::Session::accept_over(&owner, "tcp", "127.0.0.1:9162", "127.0.0.1:9163", right, budget)
				);
				let accepted = accepted.unwrap();
				let client = rooms_glowcap::client::Client::new(dialed.unwrap(), Platform::default());
				let target = client.session().fetch("ingestion").await.unwrap();
				let sources = Sources::new(Platform::default());
				let ready = tokio::sync::watch::channel(false).0;
				let description = rooms_application::files::FileDescription::parse(
					"source.bin",
					"application/octet-stream",
					33,
					0,
					0,
				)
				.unwrap();
				let lent = sources
					.lend(&client, vec![Source::reader(description, Waiting(ready.clone()))])
					.unwrap();
				let mut args = Vec::new();
				lent.append_to(&mut args);
				assert_eq!(
					client.session().send(&target, "admit", &args).await.unwrap().as_str(),
					Some("pending")
				);
				drop(args);
				assert_eq!(sources.usage().files, 1, "admission did not ingest the bytes");
				let blob = incoming.borrow_mut().take().unwrap();
				let read = owner.send(&blob, "read", &[0.into(), 17.into()]);
				let task = tokio::task::spawn_local(async move { read.await });
				while sources.usage().reads == 0 {
					environment::yield_turn().await;
				}
				drop(lent);
				assert_eq!(
					sources.usage(),
					rooms_application::files::sources::Usage {
						files: 1,
						bytes: 33,
						reads: 1
					}
				);
				ready.send_replace(true);
				assert_eq!(task.await.unwrap().unwrap().as_bytes(), Some([7; 17].as_slice()));
				assert_eq!(sources.usage(), rooms_application::files::sources::Usage::default());
				assert!(
					owner.send(&blob, "read", &[17.into(), 16.into()]).await.is_err(),
					"expired source cannot authorize another read"
				);
				client.session().close(PendingWork::Cancel).await.unwrap();
				accepted.close(PendingWork::Cancel).await.unwrap();
				sender.close(PendingWork::Cancel).await.unwrap();
				owner.close(PendingWork::Cancel).await.unwrap();
			})
			.await
			.expect("source lending journey deadline");
		})
		.await;
}

/// Exercise the production lending path without a transport, publication or
/// delivering Session. Async reads still hold the same bounded source lease.
async fn run_local() {
	tokio::task::LocalSet::new()
		.run_until(async {
			environment::within(10_000, async {
				let host = Host::from_seed([132; 32]).unwrap();
				let sources = Sources::new(Platform::default());
				let ready = tokio::sync::watch::channel(false).0;
				let description =
					rooms_application::files::FileDescription::parse("local.bin", "application/octet-stream", 33, 0, 0)
						.unwrap();
				let lent = sources
					.lend_local(&host, vec![Source::reader(description, Waiting(ready.clone()))])
					.unwrap();
				let mut args = Vec::new();
				lent.append_to(&mut args);
				let blob = Ref::try_from(&args[4]).unwrap();
				drop(args);
				let read = host.send(&blob, "read", &[0.into(), 17.into()]);
				let task = tokio::task::spawn_local(async move { read.await });
				while sources.usage().reads == 0 {
					environment::yield_turn().await;
				}
				drop(lent);
				assert_eq!(sources.usage().reads, 1, "in-flight read owns its source independently");
				ready.send_replace(true);
				assert_eq!(task.await.unwrap().unwrap().as_bytes(), Some([7; 17].as_slice()));
				assert_eq!(sources.usage(), rooms_application::files::sources::Usage::default());
				assert!(host.send(&blob, "read", &[17.into(), 16.into()]).await.is_err());
				drop((blob, sources));
				host.close(PendingWork::Cancel).await.unwrap();
			})
			.await
			.expect("local source lending deadline");
		})
		.await;
}
