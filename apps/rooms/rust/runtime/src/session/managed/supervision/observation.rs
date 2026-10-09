//! Shared wake progress, exact source checks and membership shutdown barriers.
use super::*;

impl<P: Tasks + Deadline + Clone + 'static> Worker<P> {
	pub(super) async fn cleanup(&mut self) -> Result<()> {
		let connection_lost = self.retirement.as_ref().is_some_and(|owner| owner.connection_lost());
		let closed = self
			.inbox
			.close()
			.await
			.map_err(|error| error.with_context("closing membership inbox"));
		let retired = async {
			if let Some(submission) = self.submission.as_mut() {
				// Observe the actual local admission before releasing its registry
				// slot. A lost wait cannot justify a fresh subscription at close.
				let _terminal = closing(
					&self.platform,
					submission.completed(),
					&self.finished,
					self.stopping.clone(),
					self.retrying.clone(),
					"membership admission remains pending during close",
				)
				.await;
				self.submission.take();
			}
			if let Some(retirement) = &self.retirement {
				if matches!(self.lease, Some(Lease::Direct(_))) && self.direct_retired().await? {
					let budget = self
						.budget
						.upgrade()
						.ok_or_else(|| loam::refusal("membership registry closed"))?;
					self.platform
						.within(20_000, budget.close_direct_connection(retirement))
						.await
						.ok_or_else(|| loam::refusal("direct connection retirement remains pending"))??;
				}
				self.platform
					.within(20_000, retirement.close())
					.await
					.ok_or_else(|| loam::refusal("membership retirement remains pending during close"))??;
				self.retirement.take();
			}
			Ok(())
		}
		.await
		.map_err(|error: glowcap::Error| error.with_context("retiring upstream membership"));
		// Directory retirement can obsolete a room's nickname selection before
		// its own end observer runs. Cleanup still owns the exact acquired lease.
		// Refusal by its original source cannot skip private endpoint retirement.
		let expired = if connection_lost {
			self.expire_connection_lease().await
		} else {
			Ok(())
		};
		merge(closed, merge(retired, expired))
	}
	pub(super) async fn changed(&mut self) -> Result<bool> {
		loop {
			if *self.stopping.borrow() {
				return Ok(false);
			}
			let result = tokio::select! {
			biased;
			_ = self.stopping.changed() => return Ok(false),
			_ = self.retrying.changed() => { self.changes.retry(); return Ok(true); },
			result = self.changes.changed() => result,
			};
			let result = match result {
				Ok(()) => {
					let _inspection = self.changes.inspect().await;
					self.workspace.describe_access().await.map_err(error)
				}
				Err(error) => Err(error),
			};
			match result {
				Ok(state) => {
					return Ok(!matches!(
						state.view(),
						loam::UseDescription::Revoked | loam::UseDescription::OutOfScope
					));
				}
				Err(failure) => {
					self.ready.send_replace(Some(Err(failure)));
					if !self.retry_wait().await? {
						return Ok(false);
					}
					self.ready.send_replace(self.live.then_some(Ok(())));
				}
			}
		}
	}
	async fn retry_wait(&mut self) -> Result<bool> {
		tokio::select! {
			biased;
			_ = self.stopping.changed() => Ok(false),
			result = self.retrying.changed() => {
				result.map_err(|_| loam::refusal("Membership retry owner closed"))?;
				self.changes.retry();
				Ok(true)
			},
		}
	}
}

/// A caller's deadline reports uncertainty without suspending the actual
/// receiver. Late local admission still needs polling to drive its committed
/// continuation; keeping an unpolled future would deadlock retirement.
async fn closing<P: Deadline, T>(
	platform: &P,
	pending: impl std::future::Future<Output = T>,
	finished: &watch::Sender<Option<Result<()>>>,
	mut stopping: watch::Receiver<bool>,
	mut retrying: watch::Receiver<u64>,
	message: &str,
) -> T {
	tokio::pin!(pending);
	stopping.borrow_and_update();
	retrying.borrow_and_update();
	loop {
		if let Some(result) = platform.within(20_000, pending.as_mut()).await {
			return result;
		}
		finished.send_replace(Some(Err(loam::refusal(message))));
		tokio::select! {
			result = pending.as_mut() => return result,
			_ = stopping.changed() => {},
			_ = retrying.changed() => {},
		}
	}
}
