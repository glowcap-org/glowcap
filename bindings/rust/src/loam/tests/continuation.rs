//! The public owning bridge runs on a loop-adopted Host and actual LMDB work.
use super::*;

async fn receipt_continuations_own_confirmation_and_private_results<E: Engine>(engine: EngineFn<E>) {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(std::time::Duration::from_secs(5), async {
				let directory = Directory::new();
				let mut store = Store::open(
					engine(&directory.0, OpenMode::Create, 8 * 1024 * 1024),
					&[SCHEMA],
					Limits::default(),
				)
				.unwrap();
				let resource = store
					.create_resource(&dependencies::descriptor(), SCHEMA, 1, b"owned", 2)
					.unwrap();
				let host = Host::from_seed([8; 32]).unwrap();
				let state = Rc::new(continuations::State::default());
				let mut attachment = store
					.attach(&host, vec![continuations::wrap(registration(), &state)])
					.unwrap();
				let (root, control) = attachment.restore(resource).await.unwrap();
				state.target.borrow_mut().replace(root.clone());
				let exported_control = control.clone();
				host.publish("resource", move || {
					Box::new(move |_, _| {
						Ok(Argument::List(vec![
							Argument::Reference(root.clone()),
							Argument::Reference(exported_control.clone()),
						]))
					})
				})
				.unwrap();
				let (client, server, runtime, serving) = connect(&host).await;
				let catalog = client.fetch("resource").await.unwrap();
				let opened = client.send(&catalog, "open", &[]).await.unwrap();
				let opened = opened.as_list().unwrap();
				let root = Ref::try_from(&opened[0]).unwrap();
				let management = Ref::try_from(&opened[1]).unwrap();
				continuations::exercise(&client, &root, &management, &state, 1, false).await;
				attachment.inner().unwrap().try_close().unwrap();
				assert!(host.take_failures().unwrap().is_empty());
				drop(control);
				server.close().await.unwrap();
				runtime.close(PendingWork::Cancel).await.unwrap();
				serving.await.unwrap().unwrap();
				attachment.close().await.unwrap();
				host.close(PendingWork::Cancel).await.unwrap();
				store.close().unwrap();
			})
			.await
			.expect("owning continuation consumer makes bounded progress");
		})
		.await;
}

async fn executor_abandonment_retires_unconsumed_confirmation<E: Engine>(engine: EngineFn<E>) {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(std::time::Duration::from_secs(5), async {
				let directory = Directory::new();
				let mut store = Store::open(
					engine(&directory.0, OpenMode::Create, 8 * 1024 * 1024),
					&[SCHEMA],
					Limits::default(),
				)
				.unwrap();
				let resource = store
					.create_resource(&dependencies::descriptor(), SCHEMA, 1, b"owned", 2)
					.unwrap();
				let host = Host::from_seed([8; 32]).unwrap();
				let state = Rc::new(continuations::State::default());
				let mut attachment = store
					.attach(&host, vec![continuations::wrap(registration(), &state)])
					.unwrap();
				let (target, control) = attachment.restore(resource).await.unwrap();
				let published = target.clone();
				host.publish("resource", move || {
					Box::new(move |_, _| Ok(Argument::Reference(published.clone())))
				})
				.unwrap();
				let (client, server, runtime, serving) = connect(&host).await;
				let catalog = client.fetch("resource").await.unwrap();
				let root = Ref::try_from(&client.send(&catalog, "open", &[]).await.unwrap()).unwrap();
				continuations::abandon_executor(&client, &root, state, target, 1).await;
				attachment.inner().unwrap().try_close().unwrap();
				drop(control);
				server.close().await.unwrap();
				runtime.close(PendingWork::Cancel).await.unwrap();
				serving.await.unwrap().unwrap();
				attachment.close().await.unwrap();
				assert!(host.take_failures().unwrap().is_empty());
				host.close(PendingWork::Cancel).await.unwrap();
				store.close().unwrap();
			})
			.await
			.expect("executor abandonment releases actual kernel custody");
		})
		.await;
}
#[tokio::test]
async fn lmdb_receipt_continuations_own_confirmation_and_private_results() {
	receipt_continuations_own_confirmation_and_private_results(lmdb_engine).await;
}
#[tokio::test]
async fn sqlite_receipt_continuations_own_confirmation_and_private_results() {
	receipt_continuations_own_confirmation_and_private_results(sqlite_engine).await;
}
#[tokio::test]
async fn lmdb_executor_abandonment_retires_unconsumed_confirmation() {
	executor_abandonment_retires_unconsumed_confirmation(lmdb_engine).await;
}
#[tokio::test]
async fn sqlite_executor_abandonment_retires_unconsumed_confirmation() {
	executor_abandonment_retires_unconsumed_confirmation(sqlite_engine).await;
}
#[tokio::test]
async fn volatile_receipt_continuations_own_confirmation_and_private_results() {
	receipt_continuations_own_confirmation_and_private_results(volatile_engine).await;
}
#[tokio::test]
async fn volatile_executor_abandonment_retires_unconsumed_confirmation() {
	executor_abandonment_retires_unconsumed_confirmation(volatile_engine).await;
}
