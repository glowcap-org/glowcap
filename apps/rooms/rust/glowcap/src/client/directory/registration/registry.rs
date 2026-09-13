//! Coordinate name replacements across clients sharing a directory connection.
//! A signaling name can yield to a chosen name, and cannot replace it later.
use super::{State, close, policy};
use glowcap::Ref;
use std::{
	cell::RefCell,
	rc::{Rc, Weak},
};

#[derive(Clone, Default)]
pub(crate) struct Registry(Rc<RefCell<Vec<Entry>>>);
struct Entry {
	directory: Ref,
	current: Weak<RefCell<State>>,
	claim: policy::Claim,
	pending: Weak<RefCell<State>>,
}
pub(super) struct Attempt {
	registry: Registry,
	directory: Ref,
	state: Weak<RefCell<State>>,
	claim: policy::Claim,
}
fn live(state: &Weak<RefCell<State>>) -> bool {
	state.upgrade().is_some_and(|state| !state.borrow().custody.ended())
}
impl Registry {
	pub(super) fn named(&self, directory: &Ref) -> bool {
		self.0
			.borrow()
			.iter()
			.any(|entry| &entry.directory == directory && entry.claim == policy::Claim::Named && live(&entry.current))
	}
	pub(super) fn begin(
		&self,
		directory: &Ref,
		state: &Rc<RefCell<State>>,
		claim: policy::Claim,
	) -> Result<Attempt, policy::Error> {
		let mut entries = self.0.borrow_mut();
		entries.retain(|entry| live(&entry.current) || live(&entry.pending));
		let entry = if let Some(index) = entries.iter().position(|entry| &entry.directory == directory) {
			&mut entries[index]
		} else {
			if entries.len() == policy::MAX_HELD_DIRECTORIES {
				return Err(policy::Error::Overflow);
			}
			entries.push(Entry {
				directory: directory.clone(),
				current: Weak::new(),
				claim,
				pending: Weak::new(),
			});
			entries.last_mut().expect("inserted directory")
		};
		if live(&entry.pending) {
			return Err(policy::Error::Busy);
		}
		if claim == policy::Claim::Signaling && entry.claim == policy::Claim::Named && live(&entry.current) {
			return Err(policy::Error::Claimed);
		}
		entry.pending = Rc::downgrade(state);
		Ok(Attempt {
			registry: self.clone(),
			directory: directory.clone(),
			state: Rc::downgrade(state),
			claim,
		})
	}
}
impl Attempt {
	pub fn committed(&self) {
		let prior = {
			let mut entries = self.registry.0.borrow_mut();
			let entry = entries
				.iter_mut()
				.find(|entry| entry.directory == self.directory)
				.expect("admitted registration");
			entry.claim = self.claim;
			std::mem::replace(&mut entry.current, self.state.clone())
		};
		if !prior.ptr_eq(&self.state)
			&& let Some(prior) = prior.upgrade()
		{
			close(&prior);
		}
	}
}
impl Drop for Attempt {
	fn drop(&mut self) {
		let mut entries = self.registry.0.borrow_mut();
		if let Some(entry) = entries.iter_mut().find(|entry| entry.directory == self.directory)
			&& entry.pending.ptr_eq(&self.state)
		{
			entry.pending = Weak::new();
		}
	}
}
