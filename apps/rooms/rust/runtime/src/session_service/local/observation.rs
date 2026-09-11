//! Local views borrow notifications on the service turn. Their adapters own any
//! deferred rendering queue and must admit retained files before returning.
use super::super::error::Error;
use crate::rooms::ConversationEvent;
use std::{
	cell::{Cell, RefCell},
	collections::BTreeMap,
	rc::{Rc, Weak},
};

pub trait Observer {
	fn changed(&self) -> Result<(), Error>;
	fn event(&self, event: &ConversationEvent) -> Result<(), Error>;
	fn history_changed(&self, change: &rooms_application::archive::change::Change) -> Result<(), Error>;
	fn operations_changed(&self, scope: &str) -> Result<(), Error>;
	fn closed(&self);
}
pub struct Observation {
	owner: Weak<State>,
	id: u64,
}
impl Observation {
	pub fn close(&self) {
		if let Some(owner) = self.owner.upgrade() {
			owner.rows.borrow_mut().remove(&self.id);
		}
	}
}
impl Drop for Observation {
	fn drop(&mut self) {
		self.close();
	}
}
#[derive(Clone, Default)]
pub(in crate::session_service) struct Observers(Rc<State>);
#[derive(Default)]
struct State {
	closed: Cell<bool>,
	next: Cell<u64>,
	rows: RefCell<BTreeMap<u64, Rc<dyn Observer>>>,
}
impl Observers {
	pub fn identify(&self, observation: &Observation) -> Result<u64, Error> {
		if observation.owner.ptr_eq(&Rc::downgrade(&self.0)) && self.0.rows.borrow().contains_key(&observation.id) {
			Ok(observation.id)
		} else {
			Err(Error::refused(
				"typing requires a live observation of this Rooms session",
			))
		}
	}

	pub fn attach(&self, observer: Rc<dyn Observer>) -> Result<Observation, Error> {
		if self.0.closed.get() {
			return Err(Error::refused("local Rooms views are closed"));
		}
		if self.0.rows.borrow().len() >= super::super::views::MAX_ATTACHED_VIEWS {
			return Err(Error::refused("local Rooms view limit reached"));
		}
		let id = self.0.next.get();
		let next = id
			.checked_add(1)
			.ok_or_else(|| Error::refused("local Rooms view identifiers exhausted"))?;
		self.0.rows.borrow_mut().insert(id, observer);
		self.0.next.set(next);
		Ok(Observation {
			owner: Rc::downgrade(&self.0),
			id,
		})
	}
	pub fn deliver(&self, report: &super::super::notice::Report, call: impl Fn(&dyn Observer) -> Result<(), Error>) {
		self.deliver_except(report, None, call);
	}
	pub fn deliver_except(
		&self,
		report: &super::super::notice::Report,
		except: Option<u64>,
		call: impl Fn(&dyn Observer) -> Result<(), Error>,
	) {
		let rows: Vec<_> = self
			.0
			.rows
			.borrow()
			.iter()
			.map(|(id, view)| (*id, view.clone()))
			.collect();
		for (id, view) in rows {
			if except == Some(id) || !self.0.rows.borrow().contains_key(&id) {
				continue;
			}
			if let Err(cause) = call(view.as_ref()) {
				self.0.rows.borrow_mut().remove(&id);
				view.closed();
				report(super::super::notice::Notice::ViewRetired { cause });
			}
		}
	}
	pub fn close(&self) {
		if self.0.closed.replace(true) {
			return;
		}
		let rows = std::mem::take(&mut *self.0.rows.borrow_mut());
		for (_, view) in rows {
			view.closed();
		}
	}
}
