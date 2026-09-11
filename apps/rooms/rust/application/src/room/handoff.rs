//! Transient room capability custody. Receipt never mints or persists a link.
//! Removed entries remain charged while an outstanding acceptance owns them.
use crate::session::checkpoint::reconciliation::{Field, Id};
use alloc::{rc::Rc, vec::Vec};
use core::cell::Cell;

pub const LIMIT: usize = 16;
pub const BYTES: usize = 2 * 1024 * 1024;

pub struct View {
	pub id: Id,
	pub directory: Id,
	pub label: Field,
	pub from: Field,
}
impl View {
	fn heap_bytes(&self) -> usize {
		self.id.text().heap_bytes()
			+ self.directory.text().heap_bytes()
			+ self.label.text().heap_bytes()
			+ self.from.text().heap_bytes()
	}
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	Full,
	Missing,
	Busy,
	Duplicate,
	Closed,
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Full => "this Rooms session has reached its room-handoff custody limit",
			Self::Missing => "that handed room invitation is no longer available",
			Self::Busy => "that handed room invitation is already being accepted",
			Self::Duplicate => "that handed room invitation identifier is already in use",
			Self::Closed => "the room-handoff owner has closed",
		})
	}
}
impl core::error::Error for Error {}

pub struct Held<R> {
	view: View,
	value: R,
	current: Cell<bool>,
	accepting: Cell<bool>,
	budget: Rc<Cell<(usize, usize)>>,
	bytes: usize,
}
impl<R> Held<R> {
	pub fn view(&self) -> &View {
		&self.view
	}
	pub fn value(&self) -> &R {
		&self.value
	}
	pub fn current(&self) -> bool {
		self.current.get()
	}
}
impl<R> Drop for Held<R> {
	fn drop(&mut self) {
		let (count, bytes) = self.budget.get();
		self.budget.set((count - 1, bytes - self.bytes));
	}
}
pub struct Acceptance<R>(Rc<Held<R>>);
impl<R> Acceptance<R> {
	pub fn held(&self) -> &Held<R> {
		&self.0
	}
}
impl<R> Drop for Acceptance<R> {
	fn drop(&mut self) {
		self.0.accepting.set(false);
	}
}
pub struct Handoffs<R> {
	rows: Vec<Rc<Held<R>>>,
	budget: Rc<Cell<(usize, usize)>>,
	closed: bool,
}
impl<R> Default for Handoffs<R> {
	fn default() -> Self {
		Self {
			rows: Vec::new(),
			budget: Rc::new(Cell::new((0, 0))),
			closed: false,
		}
	}
}
impl<R> Handoffs<R> {
	/// held_heap includes adapter-owned retained metadata and any reserved cache.
	/// R's inline storage and this entry's metadata are charged here.
	pub fn receive(&mut self, view: View, value: R, held_heap: usize) -> Result<(), Error> {
		if self.closed {
			return Err(Error::Closed);
		}
		if self.rows.iter().any(|row| row.view.id == view.id) {
			return Err(Error::Duplicate);
		}
		let bytes = core::mem::size_of::<Held<R>>()
			.saturating_add(view.heap_bytes())
			.saturating_add(held_heap);
		let (count, held) = self.budget.get();
		if count == LIMIT || bytes > BYTES.saturating_sub(held) {
			return Err(Error::Full);
		}
		self.budget.set((count + 1, held + bytes));
		self.rows.push(Rc::new(Held {
			view,
			value,
			current: Cell::new(true),
			accepting: Cell::new(false),
			budget: self.budget.clone(),
			bytes,
		}));
		Ok(())
	}
	pub fn rows(&self) -> impl ExactSizeIterator<Item = &Held<R>> {
		self.rows.iter().map(Rc::as_ref)
	}
	pub fn begin(&self, id: &Id) -> Result<Acceptance<R>, Error> {
		let row = self.rows.iter().find(|row| &row.view.id == id).ok_or(Error::Missing)?;
		if row.accepting.replace(true) {
			return Err(Error::Busy);
		}
		Ok(Acceptance(row.clone()))
	}
	/// Completion retires the exact offered occurrence, even if its visible id
	/// was reused after a decline while the durable transaction was pending.
	pub fn complete(&mut self, attempt: &Acceptance<R>) -> bool {
		let Some(at) = self.rows.iter().position(|row| Rc::ptr_eq(row, &attempt.0)) else {
			return false;
		};
		self.rows.remove(at).current.set(false);
		true
	}
	pub fn remove(&mut self, id: &Id) -> bool {
		let Some(at) = self.rows.iter().position(|row| &row.view.id == id) else {
			return false;
		};
		self.rows.remove(at).current.set(false);
		true
	}
	pub fn retain(&mut self, mut current: impl FnMut(&Held<R>) -> bool) -> bool {
		let before = self.rows.len();
		self.rows.retain(|row| {
			if current(row) {
				true
			} else {
				row.current.set(false);
				false
			}
		});
		before != self.rows.len()
	}
	pub fn close(&mut self) {
		self.closed = true;
		self.retain(|_| false);
	}
}
impl<R> Drop for Handoffs<R> {
	fn drop(&mut self) {
		self.close();
	}
}
