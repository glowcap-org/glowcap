//! Durable session identity, checkpoint revision, and external-effect retries.
//! Prepared writes retain an immutable candidate; only acknowledged storage can
//! publish it. Adapters own I/O retirement and execute result-application policy.
mod model;
mod operations;
mod results;
mod transaction;

pub use super::fields::{SafeInteger, Text};
use crate::{
	documents::SessionDocument,
	session::{
		checkpoint::{Checkpoint, Routes},
		snapshot::views::Adoption,
	},
	text::DocumentText,
};
use alloc::{rc::Rc, vec::Vec};
use core::cell::Cell;
pub use model::Outcome;
use model::*;
pub use operations::{Admission, Inspected, Inspection, PendingResult, PendingView};
pub use results::{ResultAdmission, ResultProgress, ResultRecorded};
pub use transaction::{Persisted, Prepared, SessionStorage};

pub type OperationId = Text<128, true>;
pub type ResultKind = Text<64, true>;
pub type ResultText = Text<32768, true>;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	Command(super::checkpoint::commands::Error),
	Document,
	Checkpoint,
	Relation,
	Busy,
	RecoveryRequired,
	WrongOwner,
	Reused,
	OtherLedger,
	Abandoned,
	Unresolved,
	Revision,
	Exhausted,
	Full,
	Missing,
	ResultInFlight,
	AdoptionClosed,
	ResultChanged,
	ResultNeedsRecovery,
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		if let Self::Command(error) = self {
			return error.fmt(f);
		}
		write!(f, "Rooms session state refusal: {self:?}")
	}
}
impl core::error::Error for Error {}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Impact {
	Presentation,
	Standing,
	Realization,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Change {
	pub revision: u64,
	pub checkpoint: Option<Impact>,
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum Phase {
	Ready,
	Writing,
	Recovery,
}

pub struct SessionState {
	disk: Disk,
	effects: Effects,
	phase: Rc<Cell<Phase>>,
	result_candidate: Option<Rc<Checkpoint>>,
}
impl SessionState {
	/// Fresh identity must be supplied by the platform entropy source. Both
	/// initial documents must be persisted before publishing this state.
	pub fn fresh(identity: [u8; 32], entropy: [u8; 16]) -> Self {
		Self {
			disk: Disk::fresh(identity, entropy),
			effects: Effects::empty(),
			phase: Rc::new(Cell::new(Phase::Ready)),
			result_candidate: None,
		}
	}
	pub fn restore(checkpoint: &[u8], effects: &[u8], routes: &impl Routes) -> Result<Self, Error> {
		let disk = Disk::decode(checkpoint, routes)?;
		let effects = Effects::decode(effects)?;
		if effects.recent.0.iter().any(|e| e.revision.get() > disk.revision.get())
			|| disk.recent.0.iter().any(|d| {
				effects.recent.0.iter().any(|e| e.id == d.id) || effects.pending.0.iter().any(|e| e.id() == &d.id)
			}) {
			return Err(Error::Relation);
		}
		Ok(Self {
			disk,
			effects,
			phase: Rc::new(Cell::new(Phase::Ready)),
			result_candidate: None,
		})
	}
	pub fn effects_are_initial(bytes: &[u8]) -> Result<bool, Error> {
		let value = Effects::decode(bytes)?;
		Ok(value.pending.0.is_empty() && value.recent.0.is_empty())
	}
	fn readable(&self) -> Result<(), Error> {
		if self.phase.get() == Phase::Recovery {
			Err(Error::RecoveryRequired)
		} else {
			Ok(())
		}
	}
	fn writable(&self) -> Result<(), Error> {
		self.readable()?;
		if self.phase.get() == Phase::Writing {
			Err(Error::Busy)
		} else {
			Ok(())
		}
	}
	pub fn revision(&self) -> Result<u64, Error> {
		self.readable()?;
		Ok(self.disk.revision.get())
	}
	pub fn checkpoint(&self) -> Result<&Checkpoint, Error> {
		self.readable()?;
		Ok(&self.disk.checkpoint)
	}
	/// Share the immutable committed graph for a pending snapshot. A later
	/// policy check still decides what that snapshot may disclose.
	pub fn checkpoint_handle(&self) -> Result<Rc<Checkpoint>, Error> {
		self.readable()?;
		Ok(self.disk.checkpoint.clone())
	}
	pub fn workspace_adoption(&self) -> Result<Adoption, Error> {
		self.readable()?;
		Ok(self.disk.workspace_adoption)
	}
	pub fn identity_seed(&self) -> Result<&[u8; 32], Error> {
		self.readable()?;
		Ok(&self.disk.identity_seed.0)
	}
	pub fn session_entropy(&self) -> Result<&[u8; 16], Error> {
		self.readable()?;
		Ok(&self.disk.session_entropy.0)
	}
	pub fn document(&self, kind: SessionDocument) -> Result<Vec<u8>, Error> {
		self.readable()?;
		match kind {
			SessionDocument::Checkpoint => model::document(&self.disk, kind),
			SessionDocument::Effects => model::document(&self.effects, kind),
			_ => Err(Error::Document),
		}
	}
	pub fn operation_known(&self, id: &OperationId) -> Result<bool, Error> {
		self.readable()?;
		Ok(self.disk.recent.0.iter().any(|v| &v.id == id)
			|| self.effects.recent.0.iter().any(|v| &v.id == id)
			|| self.effects.pending.0.iter().any(|v| v.id() == id))
	}
	pub fn pending_ids(&self) -> Result<impl ExactSizeIterator<Item = &OperationId>, Error> {
		self.readable()?;
		Ok(self.effects.pending.0.iter().map(|v| v.id()))
	}
	fn staged(&self, next: transaction::Candidate, impact: Option<Impact>) -> Result<Prepared, Error> {
		self.writable()?;
		let (kind, bytes, revision) = match &next {
			transaction::Candidate::Disk(v) => {
				v.validate()?;
				(
					SessionDocument::Checkpoint,
					model::document(v, SessionDocument::Checkpoint)?,
					v.revision.get(),
				)
			}
			transaction::Candidate::Effects(v) | transaction::Candidate::MarkedEffects(v, _) => {
				v.validate()?;
				(
					SessionDocument::Effects,
					model::document(v, SessionDocument::Effects)?,
					self.disk.revision.get(),
				)
			}
		};
		self.phase.set(Phase::Writing);
		Ok(Prepared {
			phase: self.phase.clone(),
			next: Some(next),
			kind,
			bytes: Some(bytes),
			started: false,
			change: Change {
				revision,
				checkpoint: impact,
			},
		})
	}
}
