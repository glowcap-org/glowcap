use super::*;

fn direct() -> Fact {
	Fact::DirectAccepted {
		conversation: text("direct"),
		directory: text("missing"),
		peer: text("peer"),
		registration: text("bad"),
	}
}

#[tokio::test]
async fn retired_admissions_are_discarded_including_during_shutdown_drain() {
	for shutdown in [false, true] {
		let temp = Temp::new();
		let (handle, worker) = SessionCommands::open(owner(&temp.0).await, rooms_platform::HostPlatform)
			.await
			.unwrap();
		assert!(matches!(
			handle.prepare_fact(direct()),
			Err(AdmissionError::ContextRequired)
		));
		let scope = FactScope::new();
		let reply = handle.prepare_scoped_fact(direct(), &scope).unwrap().send().unwrap();
		scope.retire();
		assert!(matches!(
			handle.prepare_scoped_fact(direct(), &scope),
			Err(AdmissionError::Retired)
		));
		let (events, trace) = events();
		if shutdown {
			handle.stop();
		}
		let exercise = async {
			let error = reply.wait().await.unwrap_err();
			assert!(matches!(error, rooms_runtime::Error::Closed(_)));
			assert!(error.to_string().contains("retired before admission"));
			if !shutdown {
				assert_eq!(handle.view().read(|state| state.revision()).unwrap().unwrap(), 0);
			}
			handle.close().await.unwrap();
		};
		let (run, ()) = tokio::join!(worker.run(events), exercise);
		run.unwrap();
		assert!(trace.borrow().revisions.is_empty());
		assert_eq!(trace.borrow().issues, [false]);
	}
}

#[tokio::test(start_paused = true)]
async fn scope_drop_wakes_failed_fact_backoff_and_releases_following_work() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let (release, clock) = hold_clock().await;
			let temp = Temp::new();
			let probe = ProbeClock::default();
			let (handle, worker) = SessionCommands::open(owner(&temp.0).await, probe.clone())
				.await
				.unwrap();
			let (mut events, _) = events();
			let (issue, mut issues) = mpsc::channel(16);
			events.issues = Some(issue);
			let task = tokio::task::spawn_local(worker.run(events));
			let scope = FactScope::new();
			assert!(
				handle
					.prepare_scoped_fact(direct(), &scope)
					.unwrap()
					.send()
					.unwrap()
					.wait()
					.await
					.is_err()
			);
			assert_eq!(issues.recv().await, Some(true));
			for seconds in [1, 2, 4, 8, 16] {
				tokio::time::advance(std::time::Duration::from_secs(seconds)).await;
				assert_eq!(issues.recv().await, Some(true));
			}
			let parked = probe.count.get() + 1;
			let next = handle.prepare_fact(reached()).unwrap().send().unwrap();
			// A fresh clock wait proves the worker consumed the queued tail and
			// re-entered backoff before the retained scope is retired.
			while probe.count.get() < parked {
				probe.changed.notified().await;
			}
			let before = tokio::time::Instant::now();
			drop(scope);
			assert_eq!(issues.recv().await, Some(false));
			next.wait().await.unwrap();
			assert_eq!(issues.recv().await, Some(false));
			assert_eq!(
				tokio::time::Instant::now(),
				before,
				"retirement must not wait thirty seconds"
			);
			handle.close().await.unwrap();
			task.await.unwrap().unwrap();
			release.send(()).unwrap();
			clock.await.unwrap();
		})
		.await;
}

#[derive(Clone, Default)]
struct ProbeClock {
	count: Rc<std::cell::Cell<usize>>,
	changed: Rc<tokio::sync::Notify>,
}
impl rooms_runtime::clock::Clock for ProbeClock {
	type Instant = tokio::time::Instant;
	fn now(&self) -> Self::Instant {
		tokio::time::Instant::now()
	}
	async fn sleep_until(&self, at: Self::Instant) {
		self.count.set(self.count.get() + 1);
		self.changed.notify_one();
		tokio::time::sleep_until(at).await;
	}
}

#[tokio::test]
async fn a_full_fact_budget_is_waited_out_rather_than_refused() {
	let temp = Temp::new();
	let (handle, worker) = SessionCommands::open(owner(&temp.0).await, rooms_platform::HostPlatform)
		.await
		.unwrap();
	let scope = FactScope::new();
	let mut held = Vec::new();
	for _ in 0..MAX_PENDING_FACTS {
		held.push(handle.prepare_scoped_fact(direct(), &scope).unwrap());
	}
	assert!(matches!(
		handle.prepare_scoped_fact(direct(), &scope),
		Err(AdmissionError::Full)
	));
	let short = std::time::Duration::from_millis(50);
	let long = std::time::Duration::from_secs(5);

	// Full is waited out, and one released permit wakes the waiter.
	let fact = direct();
	let waiting = handle.admit_scoped_fact(&fact, &scope);
	tokio::pin!(waiting);
	assert!(tokio::time::timeout(short, &mut waiting).await.is_err());
	drop(held.pop());
	let admitted = tokio::time::timeout(long, &mut waiting)
		.await
		.expect("a released permit wakes the waiter")
		.unwrap();
	held.push(admitted);

	// The scope retiring ends the wait with Retired.
	let fact = direct();
	let waiting = handle.admit_scoped_fact(&fact, &scope);
	tokio::pin!(waiting);
	assert!(tokio::time::timeout(short, &mut waiting).await.is_err());
	scope.retire();
	assert!(matches!(
		tokio::time::timeout(long, &mut waiting)
			.await
			.expect("retirement wakes the waiter"),
		Err(AdmissionError::Retired)
	));

	// The owner stopping ends the wait with Closed.
	let scope = FactScope::new();
	let fact = direct();
	let waiting = handle.admit_scoped_fact(&fact, &scope);
	tokio::pin!(waiting);
	assert!(tokio::time::timeout(short, &mut waiting).await.is_err());
	handle.stop();
	assert!(matches!(
		tokio::time::timeout(long, &mut waiting)
			.await
			.expect("stop wakes the waiter"),
		Err(AdmissionError::Closed)
	));
	drop(held);
	drop(worker);
}
