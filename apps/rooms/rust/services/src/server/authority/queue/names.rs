//! A pending authority owns its public names before persistence can yield.
//! Only the writer releases them, after a known outcome and installation.
use super::{Authority, State};
use rooms_application::failure::FailureCode;
use std::{cell::RefCell, collections::BTreeSet, rc::Rc};

#[derive(Clone, Default)]
pub(super) struct Pending(Rc<RefCell<BTreeSet<String>>>);

impl Pending {
	pub fn holds(&self, name: &str) -> bool {
		self.0.borrow().contains(&name.to_lowercase())
	}
	pub fn reserve(&self, state: &State, next: &Authority) -> Result<(), String> {
		let mut names = BTreeSet::new();
		for (name, id) in next.public_rooms() {
			let own = super::super::super::rooms::durable_key(id);
			if state.foreign.holds_name(name)
				|| state.irc.holds_name(name)
				|| state.rooms.public_key_of(name).is_some_and(|key| key != own)
			{
				return Err(FailureCode::RoomExists.line(format_args!("room \"{name}\" already exists")));
			}
			names.insert(name.to_lowercase());
		}
		*self.0.borrow_mut() = names;
		Ok(())
	}
	pub fn release(&self) {
		self.0.borrow_mut().clear();
	}
}
