//! The stand-in's receipts, held the way a session holds them
//! (`rooms_application::content::session::effects::reserve`): one per
//! operation with its base and line, at most [`MAX_EFFECTS`]. A new receipt
//! evicts the oldest one the session may forget. A send still running and a
//! committed line nobody kept are never evicted, so a sender that neither
//! keeps nor releases its receipts fills the set and its next send is
//! refused. A receipt left unknown has no work to settle it and may go,
//! though its line may have posted.
use super::super::{RoomsError, RoomsErrorKind};
use rooms_application::content::session::custody::MAX_EFFECTS;
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
	Committed,
	Pending,
	/// The session restarted before the send settled, so no work will settle
	/// it. The line may have posted.
	Unknown,
	Unsent,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Receipt {
	pub operation: String,
	pub base: u64,
	pub conversation: String,
	pub text: String,
	pub status: Status,
	pub kept: bool,
}

impl Receipt {
	fn evictable(&self) -> bool {
		match self.status {
			Status::Pending => false,
			Status::Committed => self.kept,
			Status::Unknown | Status::Unsent => true,
		}
	}
}

const FILE: &str = "receipts.json";

fn failed(error: impl ToString) -> RoomsError {
	RoomsError::new(RoomsErrorKind::Unreachable, error)
}

pub fn read(directory: &Path) -> Result<Vec<Receipt>, RoomsError> {
	match std::fs::read(directory.join(FILE)) {
		Ok(bytes) => serde_json::from_slice(&bytes).map_err(failed),
		Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
		Err(error) => Err(failed(error)),
	}
}

pub fn write(directory: &Path, receipts: &[Receipt]) -> Result<(), RoomsError> {
	let staged = directory.join(format!("{FILE}.next"));
	let bytes = serde_json::to_vec(receipts).map_err(failed)?;
	std::fs::write(&staged, bytes)
		.and_then(|()| std::fs::rename(&staged, directory.join(FILE)))
		.map_err(failed)
}

/// Hold `receipt`, evicting the oldest receipt that may go when the set is
/// full, or refuse it the way a session with no room refuses a command.
pub fn reserve(receipts: &mut Vec<Receipt>, receipt: Receipt) -> Result<(), RoomsError> {
	if receipts.len() == MAX_EFFECTS {
		let Some(oldest) = receipts.iter().position(Receipt::evictable) else {
			return Err(RoomsError::new(RoomsErrorKind::Refused, "effect receipts are full"));
		};
		receipts.remove(oldest);
	}
	receipts.push(receipt);
	Ok(())
}
