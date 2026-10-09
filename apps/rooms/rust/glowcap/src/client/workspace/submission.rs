//! Retain the actual submission receiver when interrupting a membership wait.
use super::{Command, Deadline, EffectStatus, Error};
use std::{future::Future, pin::Pin};
type Pending<T> = Pin<Box<dyn Future<Output = Result<T, Error>>>>;

/// One boxed observation retains the Host's actual vow receiver after the
/// command inputs enter its existing bounded call owner. It copies no request
/// or result. The worker lends this future to its deadline or cancellation
/// wait; dropping that wait leaves the receiver here. Replacing it before a
/// terminal result would lose evidence of a committed admission during close.
#[must_use]
pub struct Submission<T = EffectStatus> {
	pending: Option<Pending<T>>,
	result: Option<Result<T, Error>>,
}
impl<T: Clone> Submission<T> {
	pub(super) fn new(pending: impl Future<Output = Result<T, Error>> + 'static) -> Self {
		Self {
			pending: Some(Box::pin(pending)),
			result: None,
		}
	}
	/// Interrupt only this borrowed wait. Timeout retains the actual receiver.
	pub async fn within<D: Deadline>(&mut self, platform: &D, ms: u64) -> Option<Result<T, Error>> {
		platform.within(ms, self.completed()).await
	}
	/// The embedding bounds this wait while retaining this owner for recovery.
	pub async fn completed(&mut self) -> Result<T, Error> {
		if self.result.is_none() {
			self.result = Some(self.pending.as_mut().expect("unobserved submission").await);
			self.pending.take();
		}
		self.result.as_ref().expect("terminal submission").clone()
	}
}
impl<D: Deadline + 'static> Command<D> {
	/// Admit once and keep its actual completion, including during shutdown.
	/// This neither polls a receipt nor replays an unknown upstream effect.
	pub fn start_submission(&self) -> Submission {
		if let Some(sources) = &self._sources {
			sources.delivery_started();
		}
		let pending = self.caller.wait(&self.source, self.method, &self.arguments);
		Submission::new(async move { EffectStatus::read(&pending.await?) })
	}
}
