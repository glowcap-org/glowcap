//! Exact registration-scoped direct inbox aliases, shared by all directories
//! on one Host. Native publication effects commit or retire these reservations.
use crate::{directory::registration::Id, room::inbox::valid_nick};
use alloc::collections::{BTreeMap, BTreeSet};
use alloc::{
	rc::{Rc, Weak},
	string::String,
	vec::Vec,
};
use core::cell::{Cell, RefCell};
pub const DEFAULT_INBOX_LIMIT: usize = 256;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	Identity,
	Limit,
	Closed,
	Full,
	Peer,
	Registration,
	Collision,
	Foreign,
	Phase,
	Host,
	Entropy,
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Identity => "inbox scope identities are exhausted",
			Self::Limit => "inbox limit must be positive and agree with this Host",
			Self::Closed => "the inbox offerer is closed",
			Self::Full => "the Host inbox publication limit is full",
			Self::Peer => "invalid inbox peer name",
			Self::Registration => "this registration already names a different peer",
			Self::Collision => "inbox entropy collided with a retained alias",
			Self::Foreign => "the inbox scope belongs to another publisher",
			Self::Phase => "the inbox publication cannot make that transition",
			Self::Host => "the directory connection belongs to another Host",
			Self::Entropy => "could not obtain inbox entropy",
		})
	}
}
impl core::error::Error for Error {}
struct ScopeState {
	id: u64,
	active: Cell<bool>,
	inboxes: Cell<usize>,
	closed: Weak<RefCell<BTreeSet<u64>>>,
}
pub struct Scope {
	ledger: Rc<()>,
	state: Rc<ScopeState>,
}
impl Scope {
	pub fn close(&self) {
		if self.state.active.replace(false)
			&& self.state.inboxes.get() > 0
			&& let Some(closed) = self.state.closed.upgrade()
		{
			closed.borrow_mut().insert(self.state.id);
		}
	}
}
impl Drop for Scope {
	fn drop(&mut self) {
		self.close();
	}
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum Phase {
	Provisional,
	Published,
	Retiring,
	Retired,
}
struct Slot {
	ledger: Rc<()>,
	scope: Rc<ScopeState>,
	peer: String,
	registration: Rc<Id>,
	entropy: [u8; 32],
	alias: String,
	phase: Cell<Phase>,
}
#[derive(Clone)]
pub struct Inbox(Rc<Slot>);
impl Inbox {
	pub fn alias(&self) -> &str {
		&self.0.alias
	}
	pub fn peer(&self) -> &str {
		&self.0.peer
	}
	pub fn registration(&self) -> &Id {
		&self.0.registration
	}
	pub fn live(&self) -> bool {
		self.published() && self.0.scope.active.get()
	}
	pub fn published(&self) -> bool {
		self.0.phase.get() == Phase::Published
	}
	/// A factory may retire its owner. Check this exact slot again before the
	/// native alias effect; a released reservation cannot authorize publication.
	pub fn publishable(&self) -> bool {
		self.0.phase.get() == Phase::Provisional && self.0.scope.active.get()
	}
	pub fn retiring(&self) -> bool {
		self.0.phase.get() == Phase::Retiring
	}
}
/// Alias and registration indices share immutable slot/ID allocations. The
/// configured Host ceiling bounds all rows, including retirement work.
pub struct Ledger {
	key: Rc<()>,
	limit: usize,
	next_scope: u64,
	rows: BTreeMap<[u8; 32], Inbox>,
	by_scope: BTreeMap<u64, BTreeMap<Rc<Id>, Inbox>>,
	retiring: BTreeMap<[u8; 32], Inbox>,
	closed: Rc<RefCell<BTreeSet<u64>>>,
}
impl Ledger {
	pub fn validate_limit(limit: usize) -> Result<(), Error> {
		if limit == 0 { Err(Error::Limit) } else { Ok(()) }
	}
	pub fn new(limit: usize) -> Result<Self, Error> {
		Self::validate_limit(limit)?;
		Ok(Self {
			key: Rc::new(()),
			limit,
			next_scope: 0,
			rows: BTreeMap::new(),
			by_scope: BTreeMap::new(),
			retiring: BTreeMap::new(),
			closed: Rc::new(RefCell::new(BTreeSet::new())),
		})
	}
	pub fn limit(&self) -> usize {
		self.limit
	}
	pub fn held(&self) -> usize {
		self.rows.len()
	}
	pub fn scope(&mut self) -> Result<Scope, Error> {
		let id = self.next_scope.checked_add(1).ok_or(Error::Identity)?;
		self.next_scope = id;
		Ok(Scope {
			ledger: self.key.clone(),
			state: Rc::new(ScopeState {
				id,
				active: Cell::new(true),
				inboxes: Cell::new(0),
				closed: Rc::downgrade(&self.closed),
			}),
		})
	}
	fn scope_live(&self, scope: &Scope) -> Result<(), Error> {
		if !Rc::ptr_eq(&self.key, &scope.ledger) {
			return Err(Error::Foreign);
		}
		if !scope.state.active.get() {
			return Err(Error::Closed);
		}
		Ok(())
	}
	pub fn existing(&self, scope: &Scope, peer: &str, id: &Id) -> Result<Option<Inbox>, Error> {
		self.scope_live(scope)?;
		if !valid_nick(peer) {
			return Err(Error::Peer);
		}
		let found = self.by_scope.get(&scope.state.id).and_then(|rows| rows.get(id));
		if found.is_some_and(|row| row.peer() != peer) {
			return Err(Error::Registration);
		}
		Ok(found.cloned())
	}
	pub fn reserve(&mut self, scope: &Scope, peer: &str, id: &Id, entropy: [u8; 32]) -> Result<Inbox, Error> {
		if let Some(row) = self.existing(scope, peer, id)? {
			return Ok(row);
		}
		if self.rows.len() == self.limit {
			return Err(Error::Full);
		}
		if self.rows.contains_key(&entropy) {
			return Err(Error::Collision);
		}
		let alias = alloc::format!("dm-{}", crate::fields::lower_hex(&entropy));
		let row = Inbox(Rc::new(Slot {
			ledger: self.key.clone(),
			scope: scope.state.clone(),
			peer: peer.into(),
			registration: Rc::new(id.clone()),
			entropy,
			alias,
			phase: Cell::new(Phase::Provisional),
		}));
		self.rows.insert(entropy, row.clone());
		self.by_scope
			.entry(scope.state.id)
			.or_default()
			.insert(row.0.registration.clone(), row.clone());
		scope.state.inboxes.set(scope.state.inboxes.get() + 1);
		Ok(row)
	}
	fn owns(&self, row: &Inbox) -> Result<(), Error> {
		if Rc::ptr_eq(&self.key, &row.0.ledger) {
			Ok(())
		} else {
			Err(Error::Foreign)
		}
	}
	pub fn published(&mut self, row: &Inbox) -> Result<(), Error> {
		self.owns(row)?;
		if row.0.phase.get() != Phase::Provisional {
			return Err(Error::Phase);
		}
		row.0.phase.set(Phase::Published);
		Ok(())
	}
	fn detach(&mut self, row: &Inbox) {
		if let Some(rows) = self.by_scope.get_mut(&row.0.scope.id) {
			// A later alias for this registration must never be removed by the
			// retirement of its predecessor.
			if rows
				.get(row.registration())
				.is_some_and(|current| Rc::ptr_eq(&current.0, &row.0))
			{
				rows.remove(row.registration());
			}
			if rows.is_empty() {
				self.by_scope.remove(&row.0.scope.id);
			}
		}
	}
	fn release(&mut self, row: &Inbox) {
		self.rows.remove(&row.0.entropy);
		row.0.phase.set(Phase::Retired);
		let count = row.0.scope.inboxes.get() - 1;
		row.0.scope.inboxes.set(count);
		if count == 0 {
			self.closed.borrow_mut().remove(&row.0.scope.id);
		}
	}
	pub fn abandon(&mut self, row: &Inbox) -> Result<(), Error> {
		self.owns(row)?;
		if row.0.phase.get() == Phase::Provisional {
			self.detach(row);
			self.release(row);
		}
		Ok(())
	}
	fn retire(&mut self, row: &Inbox) {
		match row.0.phase.get() {
			Phase::Provisional => self.release(row),
			Phase::Published => {
				row.0.phase.set(Phase::Retiring);
				self.retiring.insert(row.0.entropy, row.clone());
			}
			_ => {}
		}
	}
	pub fn forget(&mut self, scope: &Scope, id: &Id) -> Result<(), Error> {
		self.scope_live(scope)?;
		if let Some(row) = self
			.by_scope
			.get(&scope.state.id)
			.and_then(|rows| rows.get(id))
			.cloned()
		{
			self.detach(&row);
			self.retire(&row);
		}
		Ok(())
	}
	/// Only closed scopes and already-retiring aliases are visited; ordinary
	/// offers do not scan every live registration in a shared IRC Host.
	pub fn retirements(&mut self) -> Vec<Inbox> {
		loop {
			let closed = self.closed.borrow_mut().pop_first();
			let Some(scope) = closed else { break };
			if let Some(rows) = self.by_scope.remove(&scope) {
				for row in rows.into_values() {
					self.retire(&row);
				}
			}
		}
		self.retiring.values().cloned().collect()
	}
	pub fn removed(&mut self, row: &Inbox) -> Result<(), Error> {
		self.owns(row)?;
		if row.0.phase.get() != Phase::Retiring {
			return Err(Error::Phase);
		}
		self.retiring.remove(&row.0.entropy);
		self.release(row);
		Ok(())
	}
}
impl Drop for Ledger {
	fn drop(&mut self) {
		for row in self.rows.values() {
			row.0.phase.set(Phase::Retired);
		}
	}
}
