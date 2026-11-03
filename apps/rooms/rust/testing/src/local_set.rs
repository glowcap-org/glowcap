//! The runner for a test whose scenario spawns local tasks. Each call gives
//! the future a fresh [`LocalSet`] and takes the future by value, so tasks
//! spawned by one scenario are dropped with it and never leak into the next.

use std::{future::Future, time::Duration};
use tokio::{task::LocalSet, time::timeout};

/// Run `scenario` to completion on a fresh local set.
pub async fn run<F: Future>(scenario: F) -> F::Output {
	LocalSet::new().run_until(scenario).await
}

/// Run `scenario` on a fresh local set and fail the test when it outlasts
/// `deadline`. A hung scenario is a failure, never a wait with no end.
pub async fn run_within<F: Future>(deadline: Duration, scenario: F) -> F::Output {
	match timeout(deadline, run(scenario)).await {
		Ok(output) => output,
		Err(_) => panic!("the scenario outlasted its {deadline:?} deadline"),
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::{cell::Cell, rc::Rc};

	#[tokio::test(flavor = "current_thread")]
	async fn a_scenario_may_spawn_local_tasks() {
		let seen = Rc::new(Cell::new(0));
		let output = run(async {
			let task = tokio::task::spawn_local({
				let seen = seen.clone();
				async move { seen.set(7) }
			});
			task.await.unwrap();
			seen.get()
		})
		.await;
		assert_eq!(output, 7);
	}

	#[tokio::test(flavor = "current_thread")]
	async fn a_scenario_inside_its_deadline_returns_its_output() {
		assert_eq!(run_within(Duration::from_secs(5), async { 3 }).await, 3);
	}

	#[tokio::test(flavor = "current_thread")]
	#[should_panic(expected = "outlasted its 10ms deadline")]
	async fn a_scenario_past_its_deadline_fails_the_test() {
		run_within(Duration::from_millis(10), std::future::pending::<()>()).await;
	}
}
