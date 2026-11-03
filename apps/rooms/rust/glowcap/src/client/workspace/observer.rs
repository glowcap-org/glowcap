//! One effect receipt observed through its original source and canonical
//! intent. A submitted command and a recovered receipt borrow the same four
//! fields, so they ask the receipt the same questions in one place. Only the
//! sentence naming a silent receipt differs between them.
use super::results::observed;
use super::{Caller, Deadline, EffectStatus, Error};
use glowcap::{Argument, Ref, loam};

pub(super) struct EffectObserver<'a, D> {
	pub caller: &'a Caller<D>,
	pub source: &'a Ref,
	pub operation: &'a str,
	pub canonical: &'a str,
}
impl<D: Deadline> EffectObserver<'_, D> {
	pub async fn adopted(&self) -> Result<bool, Error> {
		let reply = self
			.caller
			.call(
				self.source,
				"effect-adopted",
				&[self.operation.into()],
				"the original adoption did not answer",
			)
			.await?;
		match reply {
			Argument::Boolean(value) => Ok(value),
			_ => Err(loam::refusal("invalid adoption status").into()),
		}
	}
	pub async fn status(&self, unanswered: &'static str) -> Result<EffectStatus, Error> {
		let reply = self
			.caller
			.call(
				self.source,
				"effect-status",
				&[self.operation.into(), self.source.clone().into()],
				unanswered,
			)
			.await?;
		EffectStatus::read(&reply)
	}
	/// Wait on the original receipt and its live worker without dispatching.
	pub async fn receive(&self) -> Result<EffectStatus, Error> {
		let value = self
			.caller
			.call(
				self.source,
				"effect-reader",
				&[self.operation.into(), self.canonical.into()],
				"the original receipt observer did not answer",
			)
			.await?;
		let reader = Ref::try_from(&value).map_err(|_| loam::refusal("effect observer capability required"))?;
		EffectStatus::read(
			&self
				.caller
				.wait(&reader, "read", &[self.operation.into(), self.source.clone().into()])
				.await?,
		)
	}
	pub async fn result(&self, unanswered: &'static str) -> Result<Argument, Error> {
		self.caller
			.call(
				self.source,
				"effect-result",
				&[self.operation.into(), self.canonical.into()],
				unanswered,
			)
			.await
			.and_then(observed)
	}
}
