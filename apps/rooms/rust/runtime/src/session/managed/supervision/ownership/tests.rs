use super::*;

#[cfg(not(target_arch = "wasm32"))]
mod lifetime;

#[tokio::test]
async fn terminal_status_distinguishes_successful_retirement_from_cleanup_failure() {
	tokio::task::LocalSet::new()
		.run_until(async {
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
							Err(loam::refusal("exact cleanup failure"))
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
struct Task(tokio::task::JoinHandle<()>);
impl Drop for Task {
	fn drop(&mut self) {
		self.0.abort();
	}
}
impl Tasks for Platform {
	type Task = Task;
	fn spawn(&self, work: impl core::future::Future<Output = ()> + 'static) -> Task {
		Task(tokio::task::spawn_local(work))
	}
}

#[tokio::test]
async fn readiness_retry_during_retirement_observes_the_terminal_worker() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let budget = Rc::new(Budget::default());
			let (retire, retiring) = tokio::sync::oneshot::channel();
			let (cleanup, cleaning) = tokio::sync::oneshot::channel();
			let view = spawn(&Platform, &budget, "retiring".into(), None, |signals| async move {
				signals.ready.send_replace(Some(Ok(())));
				retiring.await.unwrap();
				signals.ready.send_replace(Some(Err(loam::refusal("connection ended"))));
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
async fn failed_retirements_charge_the_population_until_cleanup_succeeds() {
	tokio::task::LocalSet::new()
		.run_until(async {
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
							.send_replace(Some(Err(loam::refusal("cleanup unavailable"))));
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
