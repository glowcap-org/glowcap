use super::*;

#[cfg(not(target_arch = "wasm32"))]
mod lifetime;

#[tokio::test]
async fn terminal_status_distinguishes_successful_retirement_from_cleanup_failure() {
	rooms_testing::local_set::run(async {
		for failed in [false, true] {
			let budget = Rc::new(Budget::default());
			let mut view = spawn(
				&Platform,
				&budget,
				"terminal".into(),
				None,
				move |mut signals| async move {
					signals.ready.send_replace(Some(Ok(())));
					signals.stopping.changed().await.unwrap();
					if failed {
						Err(Error::platform_message("exact cleanup failure"))
					} else {
						Ok(())
					}
				},
			);
			view.ready().await.unwrap();
			let result = view.close().await;
			assert_eq!(result.is_err(), failed);
			if failed {
				let error = view.status().unwrap().unwrap_err();
				assert!(error.to_string().contains("exact cleanup failure"));
			} else {
				assert!(
					view.status().is_none(),
					"successful retirement is no longer live or failed"
				);
			}
			assert!(view.ready().await.is_err(), "retirement never restores readiness");
		}
	})
	.await;
}

struct Platform;
impl Tasks for Platform {
	type Task = rooms_testing::local_set::AbortOnDrop;
	fn spawn(&self, work: impl core::future::Future<Output = ()> + 'static) -> Self::Task {
		rooms_testing::local_set::AbortOnDrop::spawn(work)
	}
}

#[tokio::test]
async fn readiness_retry_during_retirement_observes_the_terminal_worker() {
	rooms_testing::local_set::run(async {
		let budget = Rc::new(Budget::default());
		let (retire, retiring) = tokio::sync::oneshot::channel();
		let (cleanup, cleaning) = tokio::sync::oneshot::channel();
		let view = spawn(&Platform, &budget, "retiring".into(), None, |signals| async move {
			signals.ready.send_replace(Some(Ok(())));
			retiring.await.unwrap();
			signals.ready.send_replace(Some(Err(Error::closed("connection ended"))));
			cleaning.await.unwrap();
			Ok(())
		});
		view.ready().await.unwrap();
		retire.send(()).unwrap();
		tokio::task::yield_now().await;
		assert!(matches!(view.status(), Some(Err(_))));
		view.retry();
		cleanup.send(()).unwrap();
		let result = tokio::time::timeout(std::time::Duration::from_millis(100), view.ready()).await;
		assert!(
			result.is_ok(),
			"readiness lost terminal retirement after retry cleared its failure"
		);
		assert!(result.unwrap().is_err(), "a retired membership cannot be ready");
	})
	.await;
}

#[test]
fn unspawned_startup_is_an_active_shutdown_barrier() {
	let budget = Rc::new(Budget::<Platform>::default());
	assert_eq!(budget.active(), 0);
	assert!(budget.all_closing());
	let permit = Permit::reserve(&budget).unwrap();
	assert_eq!(
		budget.active(),
		1,
		"source restoration retains its startup owner before spawning"
	);
	assert!(
		!budget.all_closing(),
		"wake feeds cannot retire beneath an unresolved start"
	);
	drop(permit);
	assert_eq!(budget.active(), 0);
	assert!(budget.all_closing());
}

#[tokio::test]
async fn stopping_a_waiting_retry_leaves_the_next_startup_slot_for_a_live_retry() {
	use core::{future::poll_fn, task::Poll};
	let budget = Rc::new(Budget::<Platform>::default());
	let mut active: Vec<_> = (0..MAX_STARTING).map(|_| Permit::reserve(&budget).unwrap()).collect();
	let mut canceled = Box::pin(Permit::resume(&budget));
	let mut remaining = Box::pin(Permit::resume(&budget));
	poll_fn(|cx| {
		assert!(canceled.as_mut().poll(cx).is_pending());
		assert!(remaining.as_mut().poll(cx).is_pending());
		Poll::Ready(())
	})
	.await;
	// The worker's stop branch drops its run future while all slots are held.
	drop(canceled);
	assert_eq!(budget.starting.get(), MAX_STARTING);
	drop(active.pop());
	let resumed = remaining.await;
	assert!(Permit::reserve(&budget).is_err());
	drop(resumed);
	assert!(Permit::reserve(&budget).is_ok());
}

#[tokio::test]
async fn failed_retirements_charge_the_population_until_cleanup_succeeds() {
	rooms_testing::local_set::run(async {
		let budget = Rc::new(Budget::default());
		let mut views = Vec::new();
		for index in 0..MAX_RETAINED {
			let permit = Permit::reserve(&budget).unwrap();
			let view = spawn(
				&Platform,
				&budget,
				index.to_string(),
				None,
				move |mut signals| async move {
					drop(permit);
					signals.ready.send_replace(Some(Ok(())));
					signals.stopping.changed().await.unwrap();
					signals
						.finished
						.send_replace(Some(Err(Error::uncertain("cleanup unavailable"))));
					signals.stopping.changed().await.unwrap();
					Ok(())
				},
			);
			view.ready().await.unwrap();
			views.push(view);
		}
		for view in &mut views {
			assert!(view.close().await.is_err());
		}
		assert_eq!(budget.active(), MAX_RETAINED);
		assert_eq!(budget.starting.get(), 0);
		assert!(
			Permit::reserve(&budget).is_err(),
			"failed cleanup cannot export cost to new rows"
		);
		views[0].close().await.unwrap();
		assert_eq!(budget.active(), MAX_RETAINED - 1);
		let replacement = Permit::reserve(&budget).unwrap();
		assert!(
			Permit::reserve(&budget).is_err(),
			"an unspawned candidate consumes the freed slot"
		);
		drop(replacement);
		for view in &mut views[1..] {
			view.close().await.unwrap();
		}
		assert_eq!(budget.active(), 0);
	})
	.await;
}
