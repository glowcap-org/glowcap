//! Live policy handles borrow the one ledger. They retain no policy snapshot.
use super::{Change, Command, Error, Grant, GrantLedger, PersistedGrant, PreparedGrant};
use alloc::{
	rc::{Rc, Weak},
	string::String,
};
use core::cell::{Ref, RefCell};

#[derive(Default)]
pub struct GrantState(Rc<RefCell<Option<GrantLedger>>>);

impl GrantState {
	pub fn install(&mut self, ledger: GrantLedger) -> Result<(), Error> {
		self.replace(Some(ledger))
	}
	pub fn clear(&mut self) -> Result<(), Error> {
		self.replace(None)
	}
	fn replace(&mut self, ledger: Option<GrantLedger>) -> Result<(), Error> {
		let mut held = self.0.try_borrow_mut().map_err(|_| Error::Busy)?;
		if held.as_ref().is_some_and(|v| v.phase.get() == super::Phase::Writing) {
			return Err(Error::Busy);
		}
		*held = ledger;
		Ok(())
	}
	pub fn ledger(&self) -> Result<Ref<'_, GrantLedger>, Error> {
		let held = self.0.try_borrow().map_err(|_| Error::Busy)?;
		let ledger = held.as_ref().ok_or(Error::RecoveryRequired)?;
		if ledger.needs_recovery() {
			return Err(Error::RecoveryRequired);
		}
		Ref::filter_map(held, Option::as_ref).map_err(|_| Error::RecoveryRequired)
	}
	pub fn prepare(&mut self, command: Command) -> Result<PreparedGrant, Error> {
		self.0
			.try_borrow_mut()
			.map_err(|_| Error::Busy)?
			.as_mut()
			.ok_or(Error::RecoveryRequired)?
			.prepare(command)
	}
	pub fn commit(&mut self, written: PersistedGrant) -> Result<Change, Error> {
		written.commit(
			self.0
				.try_borrow_mut()
				.map_err(|_| Error::Busy)?
				.as_mut()
				.ok_or(Error::RecoveryRequired)?,
		)
	}
	/// Mint only from a currently held, non-revoked record. The handle carries
	/// this owner's identity and cannot be reconstructed from a wire id.
	pub fn policy(&self, id: &str) -> Result<GrantPolicy, Error> {
		let held = self.ledger()?;
		let grant = held.get(id)?.ok_or(Error::Missing)?;
		if grant.revoked() {
			return Err(Error::Revoked);
		}
		Ok(GrantPolicy {
			owner: Rc::downgrade(&self.0),
			id: id.into(),
		})
	}
}

#[derive(Clone)]
pub struct GrantPolicy {
	owner: Weak<RefCell<Option<GrantLedger>>>,
	id: String,
}

impl GrantPolicy {
	/// Read at admission. A callback may return derived data but cannot retain
	/// a borrowed grant. Dropping the owner retires every outstanding handle.
	pub fn read<T>(&self, use_policy: impl FnOnce(&Grant) -> T) -> Result<T, Error> {
		let owner = self.owner.upgrade().ok_or(Error::Revoked)?;
		let held = owner.try_borrow().map_err(|_| Error::Busy)?;
		let grant = held
			.as_ref()
			.ok_or(Error::RecoveryRequired)?
			.get(&self.id)?
			.ok_or(Error::Revoked)?;
		if grant.revoked() {
			return Err(Error::Revoked);
		}
		Ok(use_policy(grant))
	}
}
