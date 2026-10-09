//! Restoration custody across observer cancellation and executor teardown.
use super::*;
use std::future::IntoFuture;

/// A cancelled call observer can abandon the progress lane while IndexedDB
/// still owns its Work. Attachment close must join that physical custody.
#[wasm_bindgen]
pub async fn cancelled_call_progress(saved: &str) -> Result<(), JsValue> {
	let resource = resource(saved)?;
	tokio::task::LocalSet::new()
		.run_until(async {
			let mut store = Store::open(NAME, [3; 16], false, &[SCHEMA], Limits::default())
				.await
				.map_err(message)?;
			let host = Host::from_seed([8; 32]).unwrap();
			let drops = Rc::new(Cell::new(0));
			let mut attachment = store.attach(&host, vec![registration(&drops)]).unwrap();
			let (access, control) = attachment.restore(resource).await.unwrap();
			wasm_bindgen_futures::JsFuture::from(block_storage(true)).await.unwrap();
			let mut reading = Box::pin(host.send(&access, "get", &[]).into_future());
			assert!(reading.as_mut().poll(&mut Context::from_waker(Waker::noop())).is_pending());
			wasm_bindgen_futures::JsFuture::from(wait_restore_queued()).await.unwrap();
			drop(reading);
			drop((access, control));
			let mut closing = Box::pin(attachment.close());
			assert!(
				closing.as_mut().poll(&mut Context::from_waker(Waker::noop())).is_pending(),
				"close must wait for the admitted physical read, rather than returning Busy"
			);
			assert_eq!(drops.get(), 0, "physical work still borrows the registration");
			unblock_storage();
			closing.await.unwrap();
			assert_eq!(drops.get(), 1);
			host.close(PendingWork::Cancel).await.unwrap();
			store.close().await.unwrap();
			assert!(glowcap::take_runtime_failures().is_empty());
			Ok(())
		})
		.await
}

fn start_restore(
	attachment: &glowcap::loam::Attachment,
	resource: Resource,
) -> std::pin::Pin<Box<impl Future<Output = glowcap::Result<(Ref, Ref)>> + '_>> {
	let mut restoring = Box::pin(attachment.restore(resource));
	assert!(
		restoring
			.as_mut()
			.poll(&mut Context::from_waker(Waker::noop()))
			.is_pending()
	);
	restoring
}

fn resource(saved: &str) -> Result<Resource, JsValue> {
	let saved: serde_json::Value = serde_json::from_str(saved).map_err(message)?;
	let bytes: Vec<u8> = saved["resource"]
		.as_array()
		.unwrap()
		.iter()
		.map(|v| v.as_u64().unwrap() as u8)
		.collect();
	Ok(Resource::decode(bytes.try_into().unwrap()))
}

#[wasm_bindgen]
pub async fn cancelled_restore(saved: &str) -> Result<(), JsValue> {
	let resource = resource(saved)?;

	tokio::task::LocalSet::new()
		.run_until(async {
			let mut store = Store::open(NAME, [3; 16], false, &[SCHEMA], Limits::default())
				.await
				.map_err(message)?;
			let host = Host::from_seed([8; 32]).unwrap();
			let drops = Rc::new(Cell::new(0));
			let mut attachment = store.attach(&host, vec![registration(&drops)]).unwrap();
			host.publish("echo", || Box::new(|_, _| Ok(Argument::String("responsive".into()))))
				.unwrap();
			let (caller, session, accepted) = pair(&host).await;
			let echo = session.fetch("echo").await.unwrap();
			wasm_bindgen_futures::JsFuture::from(block_storage(true)).await.unwrap();
			let mut restoring = Box::pin(attachment.restore(resource));
			assert!(
				restoring
					.as_mut()
					.poll(&mut Context::from_waker(Waker::noop()))
					.is_pending()
			);
			drop(restoring);
			wasm_bindgen_futures::JsFuture::from(wait_restore_queued())
				.await
				.unwrap();
			let mut closing = Box::pin(attachment.close());
			tokio::select! {
				biased;
				result = &mut closing => panic!("attachment retired during a blocked restore: {result:?}"),
				result = session.send(&echo, "echo", &[]) => assert_eq!(result.unwrap().as_str(), Some("responsive")),
			}
			assert_eq!(drops.get(), 0);
			assert!(store.close().await.is_err());
			unblock_storage();
			closing.await.unwrap();
			assert_eq!(drops.get(), 1);
			session.close(PendingWork::Cancel).await.unwrap();
			accepted.close(PendingWork::Cancel).await.unwrap();
			caller.close(PendingWork::Cancel).await.unwrap();
			host.close(PendingWork::Cancel).await.unwrap();
			// Close cancellation preserves its owner too. A second close joins the
			// same lock promise and must not release the C Store twice.
			let mut closing = Box::pin(store.close());
			assert!(
				closing
					.as_mut()
					.poll(&mut Context::from_waker(Waker::noop()))
					.is_pending()
			);
			drop(closing);
			store.close().await.unwrap();
			let mut reopened = Store::open(NAME, [3; 16], false, &[SCHEMA], Limits::default())
				.await
				.map_err(message)?;
			reopened.close().await.unwrap();
			assert!(glowcap::take_runtime_failures().is_empty());
			Ok(())
		})
		.await
}

#[wasm_bindgen]
pub async fn buffered_restore(saved: &str) -> Result<(), JsValue> {
	let resource = resource(saved)?;
	tokio::task::LocalSet::new()
		.run_until(async {
			for close_before_drop in [false, true] {
				let mut store = Store::open(
					NAME,
					[3; 16],
					false,
					&[SCHEMA],
					Limits {
						max_references: 2,
						..Limits::default()
					},
				)
				.await
				.map_err(message)?;
				let next = if close_before_drop {
					None
				} else {
					Some(
						store
							.create_resource(&policy(), SCHEMA, 1, b"next", 2)
							.await
							.map_err(message)?,
					)
				};
				let before = store.storage_statistics().transactions;
				let host = Host::from_seed([18; 32]).unwrap();
				let drops = Rc::new(Cell::new(0));
				let mut attachment = store.attach(&host, vec![registration(&drops)]).unwrap();
				wasm_bindgen_futures::JsFuture::from(block_storage(true)).await.unwrap();
				let restoring = start_restore(&attachment, resource);
				wasm_bindgen_futures::JsFuture::from(wait_restore_queued())
					.await
					.unwrap();
				unblock_storage();
				wasm_bindgen_futures::JsFuture::from(wait_restore_retired())
					.await
					.unwrap();
				// Both terminal events have occurred. Give the admitted relay its ready
				// poll while leaving the public observer unpolled and its result buffered.
				tokio::task::spawn_local(async {}).await.unwrap();
				assert_eq!(store.storage_statistics().transactions, before + 2);
				// A buffered, unpolled result is reference custody, not physical work.
				// It must not keep the Host's close barrier waiting on its observer.
				if close_before_drop {
					host.close(PendingWork::Cancel).await.unwrap();
				}
				drop(restoring);
				if let Some(next) = next {
					// Yield to the acknowledgement relay without any Host-driving verb.
					// Exactly two endpoint slots were occupied by the abandoned pair.
					// A different pair can restore only after that relay releases them.
					tokio::task::spawn_local(async {}).await.unwrap();
					let pair = attachment.restore(next).await.map_err(message)?;
					drop(pair);
				}
				attachment.close().await.unwrap();
				assert_eq!(drops.get(), 1);
				if !close_before_drop {
					host.close(PendingWork::Cancel).await.unwrap();
				}
				store.close().await.unwrap();
				assert!(glowcap::take_runtime_failures().is_empty());
			}
			Ok(())
		})
		.await
}

#[wasm_bindgen]
pub async fn retired_executor(saved: &str) -> Result<(), JsValue> {
	let resource = resource(saved)?;
	let executor = tokio::task::LocalSet::new();
	let (mut store, host, mut attachment, drops) = executor
		.run_until(async {
			let store = Store::open(NAME, [3; 16], false, &[SCHEMA], Limits::default())
				.await
				.unwrap();
			let host = Host::from_seed([19; 32]).unwrap();
			let drops = Rc::new(Cell::new(0));
			let attachment = store.attach(&host, vec![registration(&drops)]).unwrap();
			wasm_bindgen_futures::JsFuture::from(block_storage(true)).await.unwrap();
			let restoring = start_restore(&attachment, resource);
			wasm_bindgen_futures::JsFuture::from(wait_restore_queued())
				.await
				.unwrap();
			drop(restoring);
			(store, host, attachment, drops)
		})
		.await;
	// The delivery relay ends; its physical transaction and JS Closure cannot.
	drop(executor);
	assert_eq!(drops.get(), 0);
	unblock_storage();
	wasm_bindgen_futures::JsFuture::from(wait_restore_retired())
		.await
		.unwrap();
	assert_eq!(drops.get(), 0);
	// Later explicit Host progress adopts the parked raw occurrences; production
	// does not fabricate an executor when the embedding destroys its LocalSet.
	tokio::task::LocalSet::new()
		.run_until(async {
			attachment.close().await.unwrap();
			assert_eq!(drops.get(), 1);
			host.close(PendingWork::Cancel).await.unwrap();
			store.close().await.unwrap();
			assert!(glowcap::take_runtime_failures().is_empty());
			Ok(())
		})
		.await
}

#[wasm_bindgen]
pub async fn partial_restore(saved: &str) -> Result<(), JsValue> {
	let mut resource = resource(saved)?.encode();
	resource[66..].fill(0);
	tokio::task::LocalSet::new()
		.run_until(async {
			let mut store = Store::open(NAME, [3; 16], false, &[SCHEMA], Limits::default())
				.await
				.map_err(message)?;
			let host = Host::from_seed([20; 32]).unwrap();
			let drops = Rc::new(Cell::new(0));
			let mut attachment = store.attach(&host, vec![registration(&drops)]).unwrap();
			assert!(attachment.restore(Resource::decode(resource)).await.is_err());
			// The first occurrence was retained before the second endpoint refused.
			// It must be retired rather than leaked or dropped through a Wasm guard.
			attachment.close().await.unwrap();
			assert_eq!(drops.get(), 1);
			host.close(PendingWork::Cancel).await.unwrap();
			store.close().await.unwrap();
			assert!(glowcap::take_runtime_failures().is_empty());
			Ok(())
		})
		.await
}
