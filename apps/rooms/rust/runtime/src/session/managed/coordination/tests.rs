//! Explicit activity retry signals only failed, retained membership owners.
use super::*;
use crate::session::managed::supervision;
use std::{future::Future, num::NonZeroU64, rc::Rc};

#[derive(Clone)]
struct Platform;
impl Tasks for Platform {
	type Task = tokio::task::JoinHandle<()>;
	fn spawn(&self, work: impl Future<Output = ()> + 'static) -> Self::Task {
		tokio::task::spawn_local(work)
	}
}
impl Deadline for Platform {
	fn monotonic_millis(&self) -> u64 {
		0
	}
	async fn within<T>(&self, ms: u64, work: impl Future<Output = T>) -> Option<T> {
		tokio::time::timeout(std::time::Duration::from_millis(ms), work)
			.await
			.ok()
	}
}

#[tokio::test]
async fn explicit_retry_does_not_restart_ready_pending_or_retiring_workers() {
	tokio::task::LocalSet::new()
		.run_until(async {
			let budget = Rc::new(supervision::Budget::default());
			let mut memberships = Memberships::default();
			let mut retries = Vec::new();
			for (id, state) in ["ready", "failed", "pending", "retiring"].into_iter().enumerate() {
				let membership =
					supervision::spawn(&Platform, &budget, state.into(), None, move |mut signals| async move {
						match state {
							"ready" => {
								signals.ready.send_replace(Some(Ok(())));
							}
							"failed" => {
								signals.ready.send_replace(Some(Err(glowcap::loam::refusal(
									"rate-limited: retry-after-ms=60000; scope=join",
								))));
							}
							"retiring" => {
								signals
									.finished
									.send_replace(Some(Err(glowcap::loam::refusal("cleanup pending"))));
							}
							_ => {}
						}
						let _ = signals.stopping.changed().await;
						Ok(())
					});
				retries.push(membership.retry_signal().subscribe());
				let field = NonZeroU64::new(id as u64 + 1).unwrap();
				memberships.entries.insert(
					MembershipTarget::Direct(state.into()),
					Entry {
						origin: Origin::Direct {
							directory: rooms_application::fields::Text::new("directory".into()).unwrap(),
							peer: rooms_application::fields::Text::new(state.into()).unwrap(),
							access: None,
							introduction: None,
							source: custody::FieldKey::new(field, field),
						},
						membership,
					},
				);
			}
			tokio::task::yield_now().await;
			memberships.retry_failed();
			for (index, retry) in retries.iter().enumerate() {
				assert_eq!(*retry.borrow(), u64::from(index == 1), "wrong worker received retry");
			}
			drop(memberships);
			tokio::task::yield_now().await;
			assert_eq!(budget.active(), 0, "fixture workers must finish their owned cleanup");
		})
		.await;
}
