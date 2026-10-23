//! Restoring a cold record while a commit is in flight. The engine already
//! holds the next revision before the Host installs it, so the restore waits
//! for that work to retire instead of reading ahead of the Store.
use super::held::{Gate, HeldVolatile, Hold};
use super::*;
use std::sync::Arc;
use std::time::Duration;

#[tokio::test]
async fn a_cold_restore_waits_for_a_commit_in_flight() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(10), async {
				let gate = Arc::new(Gate::default());
				let _opened = gate.opened_on_drop();
				let policy = dependencies::descriptor();
				let mut store = Store::open(
					HeldVolatile(Arc::clone(&gate), Hold::AfterCommit),
					&[SCHEMA],
					Limits::default(),
				)
				.unwrap();
				let resource = store.create_resource(&policy, SCHEMA, 1, b"before", 0).unwrap();
				let cold = store.create_resource(&policy, SCHEMA, 1, b"cold", 0).unwrap();
				let host = Host::from_seed([9; 32]).unwrap();
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
					tokio::time::sleep(Duration::from_millis(1)).await;
				}
				// The mutation's commit has landed in the engine and its work is
				// held before the Host installs it.
				{
					let mut restoring = std::pin::pin!(attachment.restore(cold));
					assert!(
						tokio::time::timeout(Duration::from_millis(50), restoring.as_mut())
							.await
							.is_err(),
						"a cold restore waits behind the commit in flight"
					);
					gate.open();
					restoring.await.unwrap();
				}
				mutation.await.unwrap().unwrap();
				attachment.close().await.unwrap();
				drop(server);
				runtime.close(PendingWork::Cancel).await.unwrap();
				serving.await.unwrap().map(drop).unwrap_or_else(drop);
				host.close(PendingWork::Cancel).await.unwrap();
				store.close().unwrap();
			})
			.await
			.expect("restoring behind a held commit has a finite budget");
		})
		.await;
}
