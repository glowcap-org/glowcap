//! An in-memory store serves a created resource through a restored attachment.
use super::*;

#[tokio::test]
async fn volatile_store_restores_a_created_resource_and_serves_its_content() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(std::time::Duration::from_secs(5), async {
				let policy = dependencies::descriptor();
				let mut store = Store::open(
					Volatile {
						identity: [3; 16],
						capacity_bytes: 8 * 1024 * 1024,
					},
					&[SCHEMA],
					Limits::default(),
				)
				.unwrap();
				let resource = store.create_resource(&policy, SCHEMA, 1, b"in memory", 0).unwrap();
				let host = Host::from_seed([8; 32]).unwrap();
				let mut attachment = store.attach(&host, vec![registration()]).unwrap();
				let (use_ref, control) = attachment.restore(resource).unwrap();
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
				assert_text(&client, &root, b"in memory").await;
				server.close().await.unwrap();
				runtime.close(PendingWork::Cancel).await.unwrap();
				serving.await.unwrap().unwrap();
				attachment.close().await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				store.close().unwrap();
			})
			.await
			.expect("in-memory restore lifecycle has a finite CapTP budget");
		})
		.await;
}
