//! The stand-in's receipts as rows in `receipts.json`: one per operation
//! with its base and line, at most `MAX_EFFECTS` of them. What a row means to
//! the window (which keep a place, which one a new receipt evicts, what a
//! release answers) is decided by the session's own functions, through
//! `window`.
use super::super::{RoomsError, RoomsErrorKind};
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
	Committed,
	/// The send still runs. Its line has posted, and the next look finds it
	/// committed, as a session's executor settles between two calls.
	Pending,
	/// The session restarted before the send settled, so no work will settle
	/// it. The line may have posted. Like the session's paused executor, the
	/// receipt holds its place and is listed until its source releases it.
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
	#[serde(default)]
	pub released: bool,
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
