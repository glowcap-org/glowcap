//! Session-state transactions stage mutations before exposing committed effects.
use super::*;
use crate::documents::WriteFailure;

/// Storage takes ownership of bytes. A dropped future must be drained or
/// cancelled by the adapter before restore or another document operation.
pub trait SessionStorage {
	type Error;
	fn replace(
		&mut self,
		kind: SessionDocument,
		bytes: Vec<u8>,
	) -> impl core::future::Future<Output = Result<(), WriteFailure<Self::Error>>>;
}
pub(super) enum Candidate {
	Disk(Disk),
	Effects(Effects),
	MarkedEffects(Effects, Rc<Checkpoint>),
}
#[must_use]
pub struct Prepared {
	pub(super) phase: Rc<Cell<Phase>>,
	pub(super) next: Option<Candidate>,
	pub(super) kind: SessionDocument,
	pub(super) bytes: Option<Vec<u8>>,
	pub(super) started: bool,
	pub(super) change: Change,
}
impl Drop for Prepared {
	fn drop(&mut self) {
		if self.phase.get() == Phase::Writing {
			self.phase
				.set(if self.started { Phase::Recovery } else { Phase::Ready });
		}
	}
}
#[must_use]
pub struct Persisted(Prepared);
impl Prepared {
	/// The admitted checkpoint is immutable while precommit effects settle.
	pub fn checkpoint(&self) -> Option<&Checkpoint> {
		match self.next.as_ref()? {
			Candidate::Disk(disk) => Some(&disk.checkpoint),
			Candidate::MarkedEffects(_, checkpoint) => Some(checkpoint),
			Candidate::Effects(_) => None,
		}
	}
	pub async fn persist<S: SessionStorage>(mut self, store: &mut S) -> Result<Persisted, WriteFailure<S::Error>> {
		self.started = true;
		match store
			.replace(self.kind, self.bytes.take().expect("unconsumed prepared bytes"))
			.await
		{
			Ok(()) => Ok(Persisted(self)),
			Err(WriteFailure::Unchanged(e)) => {
				self.phase.set(Phase::Ready);
				Err(WriteFailure::Unchanged(e))
			}
			Err(WriteFailure::Indeterminate(e)) => Err(WriteFailure::Indeterminate(e)),
		}
	}
}
impl Persisted {
	pub fn commit(mut self, owner: &mut SessionState) -> Result<Change, Error> {
		if !Rc::ptr_eq(&self.0.phase, &owner.phase) {
			return Err(Error::WrongOwner);
		}
		match self.0.next.take().expect("unconsumed persisted candidate") {
			Candidate::Disk(v) => {
				if owner.effects.pending.0.iter().any(
					|e| matches!(e.as_ref(),Pending::Result(e) if e.marker.as_ref().is_some_and(|m|m.revision==v.revision)),
				) {
					owner.result_candidate = Some(v.checkpoint.clone());
				}
				owner.disk = v;
			}
			Candidate::Effects(v) => {
				owner.effects = v;
			}
			Candidate::MarkedEffects(v, candidate) => {
				owner.effects = v;
				owner.result_candidate = Some(candidate);
			}
		}
		if !owner
			.effects
			.pending
			.0
			.iter()
			.any(|e| matches!(e.as_ref(), Pending::Result(_)))
		{
			owner.result_candidate = None;
		}
		owner.phase.set(Phase::Ready);
		Ok(self.0.change)
	}
}
