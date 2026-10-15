//! Deployment working-set limits govern admission without changing durable grants.
use super::*;

fn invalid_forwarding_allowance_refuses_before_claiming_storage<E: Engine>(engine: EngineFn<E>) {
	let directory = Directory::new();
	for forward_reply_bytes in [0, usize::MAX] {
		let refused = Store::open(
			engine(&directory.0, OpenMode::Create, 8 * 1024 * 1024),
			&[SCHEMA],
			Limits {
				forward_reply_bytes,
				..Limits::default()
			},
		);
		assert!(refused.is_err());
	}
	// A refusal did not claim metadata: the same storage still accepts creation.
	let mut store = Store::open(
		engine(&directory.0, OpenMode::Create, 8 * 1024 * 1024),
		&[SCHEMA],
		Limits {
			max_continuations: 0,
			forward_reply_bytes: 3072,
			..Limits::default()
		},
	)
	.unwrap();
	store.close().unwrap();
}

async fn configured_managed_capacity_admits_deep_grants_after_cold_reopen<E: Engine>(engine: EngineFn<E>) {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(std::time::Duration::from_secs(5), async {
				let directory = Directory::new();
				let policy = dependencies::descriptor();
				let mut saved = None;
				let mut name = String::new();
				for (pass, record_capacity) in [24, 8, 24].into_iter().enumerate() {
					let mut store = Store::open(
						engine(
							&directory.0,
							if pass == 0 { OpenMode::Create } else { OpenMode::Open },
							256 * 1024 * 1024,
						),
						&[SCHEMA],
						Limits {
							record_capacity,
							..Limits::default()
						},
					)
					.unwrap();
					let resource = if let Some(resource) = saved {
						Resource::decode(resource)
					} else {
						let resource = store.create_resource(&policy, SCHEMA, 1, b"deep", 12).unwrap();
						saved = Some(resource.encode());
						resource
					};
					let host = Host::from_seed([8; 32]).unwrap();
					let mut attachment = store.attach(&host, vec![registration()]).unwrap();
					let (root, control) = attachment.restore(resource).unwrap();
					host.publish("resource", move || {
						let root = root.clone();
						Box::new(move |_, _| Ok(Argument::Reference(root.clone())))
					})
					.unwrap();
					let (client, server, runtime, serving) = connect(&host).await;
					let catalog = client.fetch("resource").await.unwrap();
					let root = Ref::try_from(&client.send(&catalog, "open", &[]).await.unwrap()).unwrap();
					assert_text(&client, &root, b"deep").await;
					let deepest = if pass == 0 {
						let terms = policy.value(&[10, 20], &[]).unwrap();
						let mut next = root.clone();
						for depth in (0..12).rev() {
							next = Ref::try_from(
								&client
									.send(&next, "derive", &terms.derive_arguments(1, Scope::Object, depth))
									.await
									.unwrap(),
							)
							.unwrap();
						}
						name = client
							.send(&next, "durable-name", &[])
							.await
							.unwrap()
							.as_str()
							.unwrap()
							.to_owned();
						next
					} else {
						client.fetch(&name).await.unwrap()
					};
					if record_capacity == 8 {
						let failure = client.send(&deepest, "get", &[]).await.unwrap_err();
						assert_eq!(failure.kind(), crate::ErrorKind::Broken);
						assert_eq!(failure.message(), Some("WorkingSetCapacity"));
						assert_text(&client, &root, b"deep").await;
					} else {
						assert_text(&client, &deepest, b"deep").await;
					}
					drop(control);
					server.close().await.unwrap();
					runtime.close(PendingWork::Cancel).await.unwrap();
					serving.await.unwrap().unwrap();
					attachment.close().await.unwrap();
					host.close(PendingWork::Cancel).await.unwrap();
					store.close().unwrap();
				}
			})
			.await
			.expect("deep grant lifecycle has a finite CapTP budget");
		})
		.await;
}
#[test]
fn lmdb_invalid_forwarding_allowance_refuses_before_claiming_storage() {
	invalid_forwarding_allowance_refuses_before_claiming_storage(lmdb_engine);
}
#[test]
fn sqlite_invalid_forwarding_allowance_refuses_before_claiming_storage() {
	invalid_forwarding_allowance_refuses_before_claiming_storage(sqlite_engine);
}
#[tokio::test]
async fn lmdb_configured_managed_capacity_admits_deep_grants_after_cold_reopen() {
	configured_managed_capacity_admits_deep_grants_after_cold_reopen(lmdb_engine).await;
}
#[tokio::test]
async fn sqlite_configured_managed_capacity_admits_deep_grants_after_cold_reopen() {
	configured_managed_capacity_admits_deep_grants_after_cold_reopen(sqlite_engine).await;
}
#[test]
fn volatile_invalid_forwarding_allowance_refuses_before_claiming_storage() {
	invalid_forwarding_allowance_refuses_before_claiming_storage(volatile_engine);
}
