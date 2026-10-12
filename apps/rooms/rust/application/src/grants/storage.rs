//! Grant storage transitions stage, commit, and recover durable policy changes.
use super::{Change, Error};
use crate::documents::WriteFailure;
use alloc::vec::Vec;
use core::future::Future;

/// The adapter owns cancellation of the underlying effect. After this future
/// is dropped, it must abort or drain that operation before permitting a new
/// read or write. Reloading application state cannot retire an I/O worker.
pub trait GrantStorage {
	type Error;
	/// Take the encoded document so a native adapter can transfer it to an I/O
	/// worker without copying a borrow into a second allocation.
	fn replace(&mut self, bytes: Vec<u8>) -> impl Future<Output = Result<(), WriteFailure<Self::Error>>>;
}

#[derive(Debug, PartialEq, Eq)]
pub enum ApplyError<E> {
	Policy(Error),
	Storage(WriteFailure<E>),
}

#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub(super) enum Phase {
	#[default]
	Ready,
	Writing,
	Recovery,
}

/// One prepared mutation, bound to the exact ledger that admitted it. Dropping
/// after starting storage disables that ledger until its owner restores it.
#[must_use]
pub struct PreparedGrant {
	pub(super) phase: alloc::rc::Rc<core::cell::Cell<Phase>>,
	pub(super) started: bool,
	pub(super) next: Option<super::Grant>,
	pub(super) bytes: Option<Vec<u8>>,
	pub(super) change: Change,
}

impl Drop for PreparedGrant {
	fn drop(&mut self) {
		if self.phase.get() == Phase::Writing {
			self.phase
				.set(if self.started { Phase::Recovery } else { Phase::Ready });
		}
	}
}

/// Evidence that storage acknowledged this exact mutation. Only this value can
/// commit it. Dropping the acknowledgement also requires recovery.
#[must_use]
pub struct PersistedGrant(PreparedGrant);

impl PreparedGrant {
	pub async fn persist<S: GrantStorage>(mut self, store: &mut S) -> Result<PersistedGrant, ApplyError<S::Error>> {
		if let Some(bytes) = self.bytes.take() {
			self.started = true;
			match store.replace(bytes).await {
				Ok(()) => (),
				Err(WriteFailure::Unchanged(error)) => {
					self.phase.set(Phase::Ready);
					return Err(ApplyError::Storage(WriteFailure::Unchanged(error)));
				}
				Err(WriteFailure::Indeterminate(error)) => {
					return Err(ApplyError::Storage(WriteFailure::Indeterminate(error)));
				}
			}
		}
		Ok(PersistedGrant(self))
	}
}

impl PersistedGrant {
	pub fn commit(mut self, ledger: &mut super::GrantLedger) -> Result<Change, Error> {
		if !alloc::rc::Rc::ptr_eq(&self.0.phase, &ledger.phase) {
			return Err(Error::WrongOwner);
		}
		if let Some(grant) = self.0.next.take() {
			if self.0.change == Change::Issued {
				ledger.active += 1;
			}
			if self.0.change == Change::Revoked {
				ledger.active -= 1;
			}
			if let Some(&at) = ledger.by_id.get(&grant.id) {
				ledger.grants[at] = grant;
			} else {
				ledger.by_id.insert(grant.id.clone(), ledger.grants.len());
				ledger.grants.push(grant);
			}
		}
		ledger.phase.set(Phase::Ready);
		Ok(self.0.change)
	}
}
