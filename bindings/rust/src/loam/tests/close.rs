//! Closing a Host while a storage work is in flight. Each work runs as its
//! own task, so the close driver settles storage before it releases the
//! attachment.
use super::held::{Gate, HeldVolatile, Hold};
use super::*;
use std::sync::Arc;

#[tokio::test]
async fn host_close_settles_a_storage_work_in_flight() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(std::time::Duration::from_secs(10), async {
				let gate = Arc::new(Gate::default());
				let policy = dependencies::descriptor();
				let mut store = Store::open(
					HeldVolatile(Arc::clone(&gate), Hold::BeforeRun),
					&[SCHEMA],
					Limits::default(),
				)
				.unwrap();
				let resource = store.create_resource(&policy, SCHEMA, 1, b"before", 0).unwrap();
				let host = Host::from_seed([8; 32]).unwrap();
				let mut attachment = store.attach(&host, vec![registration()]).unwrap();
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
				let mutation = tokio::task::spawn_local(async move { client.send(&root, "mutate", &request).await });
				while gate.entered() == 0 {
					tokio::time::sleep(std::time::Duration::from_millis(1)).await;
				}
				// The Host closes while its storage work is held, and the work
				// retires only once the close driver is already waiting. The
				// gate opens off this thread, so a failed close that drops the
				// held task still lets its blocking join finish.
				let release = Arc::clone(&gate);
				let opener = std::thread::spawn(move || {
					std::thread::sleep(std::time::Duration::from_millis(50));
					release.open();
				});
				let closed = host.close(PendingWork::Cancel).await;
				opener.join().unwrap();
				closed.unwrap();
				// The mutation may commit or fail with the closed session, and
				// either way it settles.
				mutation.await.unwrap().map(drop).unwrap_or_else(drop);
				attachment.close().await.unwrap();
				// Host close closed the listener with its loop.
				drop(server);
				runtime.close(PendingWork::Cancel).await.unwrap();
				serving.await.unwrap().map(drop).unwrap_or_else(drop);
				store.close().unwrap();
			})
			.await
			.expect("closing over held storage has a finite budget");
		})
		.await;
}
