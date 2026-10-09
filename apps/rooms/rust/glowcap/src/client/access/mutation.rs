//! Prepared edits retain the exact control, sequence and expected revision.
//! Submission never reads a newer revision or obtains another receipt identity.
use super::{Caller, Control};
use crate::client::{Deadline, Error};
use glowcap::{Argument, Ref, loam::PolicyValue};

/// One owning request survives both caller cancellation and lost acknowledgment.
/// The control guard prevents retargeting; the argument vector keeps the receipt
/// sequence, expected revision and complete candidate together. Policy and label
/// use the binding's existing encoders. Lifecycle owns three argument slots,
/// one fixed verb and eight revision bytes. Dropping these inputs after sending
/// would make recovery require a fresh sequence or revision. `retained_bytes`
/// charges the complete vector and leaf capacities without encoding them again.
pub struct Mutation<D> {
	caller: Caller<D>,
	control: Ref,
	arguments: Vec<Argument>,
}
impl<D> Mutation<D> {
	pub fn retained_bytes(&self) -> usize {
		size_of::<Self>().saturating_add(crate::client::retained::vector(&self.arguments))
	}
}
impl<D: Deadline> Mutation<D> {
	pub async fn submit(&self) -> Result<(), Error> {
		self.caller
			.call(
				&self.control,
				"mutate",
				&self.arguments,
				"the access control did not answer",
			)
			.await?;
		Ok(())
	}
}
impl<D: Deadline + Clone> Control<D> {
	async fn prepare_mutation(&self, arguments: impl FnOnce(u32) -> Vec<Argument>) -> Result<Mutation<D>, Error> {
		let sequence = self.mutation_sequence().await?;
		Ok(Mutation {
			caller: self.caller.clone(),
			control: self.reference.clone(),
			arguments: arguments(sequence),
		})
	}
	pub async fn prepare_policy(&self, revision: u64, policy: PolicyValue) -> Result<Mutation<D>, Error> {
		self.prepare_mutation(|sequence| policy.set_policy_arguments(sequence, revision))
			.await
	}
	pub async fn prepare_label(&self, revision: u64, label: &str) -> Result<Mutation<D>, Error> {
		self.prepare_mutation(|sequence| glowcap::loam::ControlPowers::label_arguments(sequence, revision, label))
			.await
	}
	pub async fn prepare_pause(&self, revision: u64) -> Result<Mutation<D>, Error> {
		self.prepare_lifecycle("pause", revision).await
	}
	pub async fn prepare_resume(&self, revision: u64) -> Result<Mutation<D>, Error> {
		self.prepare_lifecycle("resume", revision).await
	}
	pub async fn prepare_revoke(&self, revision: u64) -> Result<Mutation<D>, Error> {
		self.prepare_lifecycle("revoke", revision).await
	}
	async fn prepare_lifecycle(&self, verb: &'static str, revision: u64) -> Result<Mutation<D>, Error> {
		self.prepare_mutation(|sequence| {
			vec![
				i64::from(sequence).into(),
				verb.into(),
				Argument::Bytes(revision.to_be_bytes().to_vec()),
			]
		})
		.await
	}
}
