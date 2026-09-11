//! Registration-scoped wakeups for bounded direct introductions.
use super::registration::Id;
use alloc::{collections::VecDeque, rc::Rc, vec::Vec};

pub const INTRODUCE: &str = "introduce";
pub const MAX_OUTSTANDING: usize = 256;
pub const WAIT_MS: u64 = 10_000;

/// First contact may consume one early notification. A second refusal must
/// wait for a fresh offer; a third refusal ends this introduction.
#[derive(Default)]
pub struct Retries(u8);
impl Retries {
	pub fn next_wait(&mut self) -> Option<bool> {
		let banked = match self.0 {
			0 => true,
			1 => false,
			_ => return None,
		};
		self.0 += 1;
		Some(banked)
	}
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	Full,
	Ended,
	Missing,
	Capability,
	Pending,
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Full => "the directory has too many direct introductions in progress",
			Self::Ended => "the directory connection ended",
			Self::Missing => "the introduction wait has ended",
			Self::Capability => "the directory did not return a direct inbox capability",
			Self::Pending => "introduction-pending: the peer did not offer an inbox",
		})
	}
}
impl core::error::Error for Error {}
#[derive(Clone, Debug)]
pub struct Ticket {
	serial: u64,
	owner: Rc<()>,
}
impl PartialEq for Ticket {
	fn eq(&self, other: &Self) -> bool {
		self.serial == other.serial && Rc::ptr_eq(&self.owner, &other.owner)
	}
}
impl Eq for Ticket {}
struct Waiting<W> {
	ticket: u64,
	id: Id,
	ready: bool,
	wake: W,
}
/// W is an opaque platform wake token. The core returns wake effects; it never
/// runs them. Ready but unobserved waits still count against the retained bound.
pub struct Notices<W> {
	owner: Rc<()>,
	bank: VecDeque<Id>,
	waiting: Vec<Waiting<W>>,
	serial: u64,
}
impl<W> Default for Notices<W> {
	fn default() -> Self {
		Self {
			owner: Rc::new(()),
			bank: VecDeque::new(),
			waiting: Vec::new(),
			serial: 0,
		}
	}
}
impl<W> Notices<W> {
	/// A banked notification can satisfy only the first retry. A subsequent
	/// refusal requires a notification arriving after the fresh wait begins.
	pub fn wait(&mut self, id: &Id, use_banked: bool, wake: W) -> Result<Option<Ticket>, Error> {
		if use_banked {
			if let Some(at) = self.bank.iter().position(|entry| entry == id) {
				self.bank.remove(at);
				self.trim();
				return Ok(None);
			}
		}
		if self.waiting.len() == MAX_OUTSTANDING {
			return Err(Error::Full);
		}
		let serial = self.serial.checked_add(1).ok_or(Error::Full)?;
		self.serial = serial;
		let ticket = Ticket {
			serial,
			owner: self.owner.clone(),
		};
		self.waiting.push(Waiting {
			ticket: serial,
			id: id.clone(),
			ready: false,
			wake,
		});
		Ok(Some(ticket))
	}
	pub fn observe(&mut self, ticket: &Ticket, wake: W) -> Result<bool, Error> {
		if !Rc::ptr_eq(&self.owner, &ticket.owner) {
			return Err(Error::Missing);
		}
		let at = self
			.waiting
			.iter()
			.position(|entry| entry.ticket == ticket.serial)
			.ok_or(Error::Missing)?;
		if self.waiting[at].ready {
			self.waiting.swap_remove(at);
			self.trim();
			Ok(true)
		} else {
			self.waiting[at].wake = wake;
			Ok(false)
		}
	}
	pub fn cancel(&mut self, ticket: &Ticket) {
		if !Rc::ptr_eq(&self.owner, &ticket.owner) {
			return;
		}
		if let Some(at) = self.waiting.iter().position(|entry| entry.ticket == ticket.serial) {
			self.waiting.swap_remove(at);
			self.trim();
		}
	}
	fn trim(&mut self) {
		if self.waiting.is_empty() {
			self.waiting = Vec::new();
		}
		if self.bank.is_empty() {
			self.bank = VecDeque::new();
		}
	}
}
impl<W: Clone> Notices<W> {
	pub fn notify(&mut self, id: &Id) -> Vec<W> {
		// At most MAX_OUTSTANDING wake tokens cross the platform boundary.
		// Collecting them permits the adapter to wake after releasing its borrow.
		let mut wake = Vec::new();
		for entry in &mut self.waiting {
			if !entry.ready && &entry.id == id {
				entry.ready = true;
				wake.push(entry.wake.clone());
			}
		}
		if wake.is_empty() && !self.bank.contains(id) {
			if self.bank.len() == MAX_OUTSTANDING {
				self.bank.pop_front();
			}
			self.bank.push_back(id.clone());
		}
		wake
	}
}
