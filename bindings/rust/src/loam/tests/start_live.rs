//! A restarted lifetime confirms through its own marker read. A call that
//! commits meanwhile makes that read stale and sends startup back to read, so
//! `start_live` resolves only once the lifetime is confirmed, and settles when
//! its Host goes away.
use super::held::{Gate, HeldVolatile, Hold};
use super::*;
use std::sync::Arc;
use std::time::Duration;

const BUDGET: Duration = Duration::from_secs(10);
const POLL: Duration = Duration::from_millis(50);

/// A store whose first lifetime is confirmed and closed, so the next
/// `start_live` carries a previous marker. Reads hold once the gate is armed.
struct Restarted {
	store: Store,
	host: Host,
	attachment: Attachment,
	resource: Resource,
	marker: LiveMarker,
	generation: LiveIncarnation,
}
async fn restarted(gate: &Arc<Gate>) -> Restarted {
	let policy = dependencies::descriptor();
	let store = Store::open(
		HeldVolatile(Arc::clone(gate), Hold::ArmedReads),
		&[SCHEMA],
		Limits::default(),
	)
	.unwrap();
	let resource = store.create_resource(&policy, SCHEMA, 1, b"before", 2).unwrap();
	let saved = resource.encode();
	let host = Host::from_seed([8; 32]).unwrap();
	let mut first = store.attach(&host, vec![registration()]).unwrap();
	let generation = first.start_live(None, 2).await.unwrap();
	first.close().await.unwrap();
	host.close(PendingWork::Cancel).await.unwrap();
	let host = Host::from_seed([8; 32]).unwrap();
	let attachment = store.attach(&host, vec![registration()]).unwrap();
	Restarted {
		store,
		host,
		attachment,
		resource: Resource::decode(saved),
		marker: generation.marker(),
		generation,
	}
}

async fn pending<T>(future: std::pin::Pin<&mut impl std::future::Future<Output = T>>) -> bool {
	tokio::time::timeout(POLL, future).await.is_err()
}

#[tokio::test]
async fn a_committed_write_does_not_confirm_a_restarted_lifetime() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(BUDGET, async {
				let gate = Arc::new(Gate::default());
				let _opened = gate.opened_on_drop();
				let Restarted {
					mut store,
					host,
					mut attachment,
					resource,
					marker,
					generation,
				} = restarted(&gate).await;
				let (use_ref, control) = attachment.restore(resource).await.unwrap();
				let pair = vec![Argument::Reference(use_ref), Argument::Reference(control)];
				host.publish("resource", move || {
					let pair = pair.clone();
					Box::new(move |_, _| Ok(Argument::List(pair.clone())))
				})
				.unwrap();
				let (client, server, runtime, serving) = connect(&host).await;
				let catalog = client.fetch("resource").await.unwrap();
				let opened = client.send(&catalog, "open", &[]).await.unwrap();
				let root = Ref::try_from(&opened.as_list().unwrap()[0]).unwrap();
				let request = [
					Argument::Integer(1),
					Argument::String("set".to_owned()),
					Argument::Bytes(b"after".to_vec()),
				];
				gate.arm();
				let confirmed = {
					let mut starting = std::pin::pin!(attachment.start_live(Some(marker), 2));
					assert!(
						pending(starting.as_mut()).await,
						"startup waits on its held marker read"
					);
					assert_eq!(gate.entered(), 1, "startup is the held read");
					// An ordinary write commits while the read is outstanding.
					client.send(&root, "mutate", &request).await.unwrap();
					assert!(attachment.live_marker().unwrap().is_none());
					assert!(
						pending(starting.as_mut()).await,
						"the committed write did not confirm startup"
					);
					gate.open();
					starting.await.unwrap()
				};
				assert_eq!(confirmed.marker(), attachment.live_marker().unwrap().unwrap());
				assert_ne!(confirmed, generation);
				assert_eq!(confirmed.encode()[33..], 2u64.to_be_bytes(), "the next generation");
				server.close().await.unwrap();
				runtime.close(PendingWork::Cancel).await.unwrap();
				serving.await.unwrap().map(drop).unwrap_or_else(drop);
				drop(client);
				attachment.close().await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				store.close().unwrap();
			})
			.await
			.expect("startup over a held read has a finite budget");
		})
		.await;
}

#[tokio::test]
async fn a_host_closing_settles_a_start_live_waiting_on_storage() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(BUDGET, async {
				let gate = Arc::new(Gate::default());
				let _opened = gate.opened_on_drop();
				let Restarted {
					mut store,
					host,
					mut attachment,
					marker,
					..
				} = restarted(&gate).await;
				gate.arm();
				let starting = attachment.start_live(Some(marker), 2);
				let closing = async {
					while gate.entered() == 0 {
						tokio::time::sleep(Duration::from_millis(1)).await;
					}
					let release = Arc::clone(&gate);
					let opener = std::thread::spawn(move || {
						std::thread::sleep(POLL);
						release.open();
					});
					let closed = host.close(PendingWork::Cancel).await;
					opener.join().unwrap();
					closed
				};
				let (started, closed) = tokio::join!(starting, closing);
				closed.unwrap();
				// Either the startup finished before the close took the Host
				// or it refuses with the closed Host. It never stays pending.
				if let Err(error) = started {
					assert!(error.to_string().contains("closed"), "{error}");
				}
				attachment.close().await.unwrap();
				store.close().unwrap();
			})
			.await
			.expect("a waiting start_live settles when its Host closes");
		})
		.await;
}

#[tokio::test]
async fn dropping_start_live_leaves_startup_to_finish() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(BUDGET, async {
				let gate = Arc::new(Gate::default());
				let _opened = gate.opened_on_drop();
				let Restarted {
					mut store,
					host,
					mut attachment,
					marker,
					generation,
					..
				} = restarted(&gate).await;
				gate.arm();
				{
					let mut starting = std::pin::pin!(attachment.start_live(Some(marker), 2));
					assert!(pending(starting.as_mut()).await);
				}
				// Startup belongs to the attachment, not to the cancelled wait.
				assert!(attachment.live_incarnation().unwrap().is_none());
				assert!(
					attachment.start_live(Some(marker), 2).await.is_err(),
					"a second start refuses while the first runs"
				);
				gate.open();
				let confirmed = loop {
					if let Some(confirmed) = attachment.live_incarnation().unwrap() {
						break confirmed;
					}
					tokio::task::yield_now().await;
				};
				assert_ne!(confirmed, generation);
				attachment.close().await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				store.close().unwrap();
			})
			.await
			.expect("a dropped start_live still lets startup finish");
		})
		.await;
}
