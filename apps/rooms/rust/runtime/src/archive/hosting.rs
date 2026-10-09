//! Retained facet storage and nonrefundable issuance belong to one archive owner.
use super::{CALLER_LIMIT, FACET_BYTES};
use crate::Error;
use glowcap::{Ref, Session};
use rooms_application::archive::{
	blobs::MAX_READERS_PER_SESSION,
	request::{Issuance, MintBudget},
};
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
};
#[derive(Default)]
pub(crate) struct Budget {
	bytes: Rc<Cell<usize>>,
	callers: RefCell<Vec<Caller>>,
	local_facets: RefCell<Issuance>,
	local_readers: RefCell<MintBudget<MAX_READERS_PER_SESSION>>,
}
struct Caller {
	session: Session,
	facets: Issuance,
	readers: MintBudget<MAX_READERS_PER_SESSION>,
}
pub(crate) enum Kind {
	Facet,
	Reader,
}
pub(crate) struct Permit {
	bytes: usize,
	held: Rc<Cell<usize>>,
}
impl Drop for Permit {
	fn drop(&mut self) {
		self.held.set(self.held.get() - self.bytes);
	}
}
impl Budget {
	/// Local managed readers have no calling transport session. Their issuance
	/// is still cumulative and belongs to the same archive account budget.
	pub fn mint_local(&self, kind: Kind, create: impl FnOnce() -> Result<Ref, Error>) -> Result<Ref, Error> {
		if matches!(kind, Kind::Reader) {
			let mut readers = self.local_readers.borrow_mut();
			if !readers.available() {
				return Err(Error::exhausted("local archive reader ceiling reached"));
			}
			let reference = create()?;
			readers
				.minted()
				.expect("local reader issuance checked in the same turn");
			return Ok(reference);
		}
		let mut facets = self.local_facets.borrow_mut();
		if !facets.available() {
			return Err(Error::exhausted("local archive mint ceiling reached"));
		}
		let reference = create()?;
		facets.minted().expect("local issuance checked in the same turn");
		Ok(reference)
	}
	pub fn bytes(&self) -> usize {
		self.bytes.get()
	}
	pub fn callers(&self) -> usize {
		self.callers.borrow().len()
	}
	pub fn retain(&self, bytes: usize) -> Result<Permit, Error> {
		if bytes > FACET_BYTES.saturating_sub(self.bytes.get()) {
			return Err(Error::exhausted("archive facet storage is full"));
		}
		self.bytes.set(self.bytes.get() + bytes);
		Ok(Permit {
			bytes,
			held: self.bytes.clone(),
		})
	}
	/// The mint and charge happen in one turn; releasing the occurrence never
	/// refunds the caller's work. The retained session borrows transport custody.
	pub fn mint(
		&self,
		session: &Session,
		kind: Kind,
		create: impl FnOnce() -> Result<Ref, Error>,
	) -> Result<Ref, Error> {
		let mut callers = self.callers.borrow_mut();
		callers.retain(|caller| caller.session.is_open());
		let at = match callers.iter().position(|caller| caller.session.same_session(session)) {
			Some(at) => at,
			None => {
				if callers.len() == CALLER_LIMIT {
					return Err(Error::exhausted("archive caller limit reached"));
				}
				callers.push(Caller {
					session: session.borrowed(),
					facets: Issuance::new(),
					readers: Default::default(),
				});
				callers.len() - 1
			}
		};
		let caller = &mut callers[at];
		let available = match kind {
			Kind::Facet => caller.facets.available(),
			Kind::Reader => caller.readers.available(),
		};
		if !available {
			return Err(Error::exhausted("archive mint ceiling reached for this session"));
		}
		let reference = create()?;
		match kind {
			Kind::Facet => caller.facets.minted(),
			Kind::Reader => caller.readers.minted(),
		}
		.expect("issuance checked in the same synchronous turn");
		Ok(reference)
	}
}
