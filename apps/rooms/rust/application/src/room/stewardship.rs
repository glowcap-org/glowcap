//! Authority custody for one membership, independent of transport and executor.
use super::authority::Refusal;
use alloc::{
	rc::{Rc, Weak},
	string::String,
};
use core::cell::Cell;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
	Room,
	Steward,
	Manager,
}

/// A validated sturdyref and its decoded publication generation. The adapter
/// supplies the token through the existing binding's sturdyref parser.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Publication {
	link: String,
	token: String,
}
impl Publication {
	pub fn new(link: String, token: String) -> Result<Self, Refusal> {
		if link.is_empty() || token.is_empty() {
			return Err(Refusal::Token);
		}
		Ok(Self { link, token })
	}
	pub fn link(&self) -> &str {
		&self.link
	}
	pub fn token(&self) -> &str {
		&self.token
	}
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	Busy,
	Retired,
	NoManager,
	NoSteward,
	StewardRetired,
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		match self {
			Self::Busy => f.write_str("room authority acquisition is already pending"),
			Self::Retired => f.write_str("room authority changed while acquisition was pending"),
			Self::NoManager => f.write_str("this room does not retain its manager capability"),
			Self::NoSteward => f.write_str("this room did not hand over its steward"),
			Self::StewardRetired => core::fmt::Display::fmt(
				&crate::failure::Failure {
					code: crate::failure::FailureCode::NotSteward,
					detail: "this moderator capability was retired",
				},
				f,
			),
		}
	}
}
impl core::error::Error for Error {}

/// One bounded acquisition. Dropping it frees admission; notices invalidate it
/// without freeing its seat before the outstanding observation actually ends.
pub struct Attempt(Rc<Cell<bool>>);
impl Attempt {
	pub fn check(&self) -> Result<(), Error> {
		if self.0.get() {
			Ok(())
		} else {
			Err(Error::Retired)
		}
	}
}
pub enum Acquisition<R> {
	Room(Publication),
	Manager(Publication),
	Steward {
		room: Publication,
		publication: Publication,
		reference: R,
	},
}

pub struct Stewardship<R> {
	room: Option<Publication>,
	manager: Option<Publication>,
	steward: Option<Publication>,
	reference: Option<R>,
	retired: bool,
	pending: Weak<Cell<bool>>,
}
impl<R> Default for Stewardship<R> {
	fn default() -> Self {
		Self {
			room: None,
			manager: None,
			steward: None,
			reference: None,
			retired: false,
			pending: Weak::new(),
		}
	}
}
impl<R> Stewardship<R> {
	pub fn room(&self) -> Option<&Publication> {
		self.room.as_ref()
	}
	pub fn manager(&self) -> Option<&Publication> {
		self.manager.as_ref()
	}
	pub fn steward(&self) -> Option<&Publication> {
		self.steward.as_ref()
	}
	pub fn held(&self) -> bool {
		self.reference.is_some()
	}
	pub fn reference(&self) -> Result<&R, Error> {
		self.reference.as_ref().ok_or(if self.retired {
			Error::StewardRetired
		} else {
			Error::NoSteward
		})
	}
	pub fn begin(&mut self) -> Result<Attempt, Error> {
		if self.pending.upgrade().is_some() {
			return Err(Error::Busy);
		}
		let attempt = Attempt(Rc::new(Cell::new(true)));
		self.pending = Rc::downgrade(&attempt.0);
		Ok(attempt)
	}
	/// The caller has validated the reply and imported any new reference.
	/// Failure drops that candidate and preserves the previously held authority.
	pub fn accept(&mut self, attempt: Attempt, acquisition: Acquisition<R>) -> Result<(), Error> {
		attempt.check()?;
		if !self.pending.ptr_eq(&Rc::downgrade(&attempt.0)) {
			return Err(Error::Retired);
		}
		match acquisition {
			Acquisition::Room(room) => self.room = Some(room),
			Acquisition::Manager(manager) => self.manager = Some(manager),
			Acquisition::Steward {
				room,
				publication,
				reference,
			} => {
				self.room = Some(room);
				self.steward = Some(publication);
				self.reference = Some(reference);
				self.retired = false;
			}
		}
		self.pending = Weak::new();
		Ok(())
	}
	fn invalidate(&self) {
		if let Some(pending) = self.pending.upgrade() {
			pending.set(false);
		}
	}
	/// Exact generations control retained state. Any notice invalidates pending
	/// acquisition: its returned publication may not yet be known to this owner.
	/// No list of retired tokens or unbounded pending work is retained.
	pub fn forget(&mut self, kind: Kind, token: &str) {
		self.invalidate();
		match kind {
			Kind::Room if self.room.as_ref().is_some_and(|p| p.token == token) => {
				self.room = None;
				self.steward = None;
				self.reference = None;
				self.retired = true;
			}
			Kind::Steward if self.steward.as_ref().is_some_and(|p| p.token == token) => {
				self.steward = None;
				self.reference = None;
				self.retired = true;
			}
			Kind::Manager if self.manager.as_ref().is_some_and(|p| p.token == token) => self.manager = None,
			_ => {}
		}
	}
	pub fn drop_steward(&mut self) {
		self.invalidate();
		self.reference = None;
		self.steward = None;
		self.retired = false;
	}
	pub fn drop_manager(&mut self) {
		self.invalidate();
		self.manager = None;
	}
	/// Reconnect cleanup keeps durable links and never revokes other holders.
	pub fn release(&mut self) {
		self.invalidate();
		self.reference = None;
	}
}
