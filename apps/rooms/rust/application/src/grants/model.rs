//! Durable grant documents encode policy without carrying live authority.
use crate::text::DocumentText;
use alloc::string::String;
use core::fmt;
use serde::{Deserialize, Serialize};

pub const MAX_ACTIVE_GRANTS: usize = 32;
pub const MAX_LIFETIME_GRANTS: usize = 256;
pub const MAX_GRANT_LABEL_UNITS: usize = 80;
pub const MAX_GRANT_NOTE_UNITS: usize = 200;
pub const MAX_DOCUMENT_BYTES: usize = crate::documents::SessionDocument::Grants.max_bytes();

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Rights {
	Observe,
	Interact,
	Admin,
}

/// A display of current access. It does not confer a capability.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Access {
	None,
	Observe,
	Interact,
	Admin,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Grant {
	pub(super) id: String,
	pub(super) label: DocumentText,
	pub(super) rights: Rights,
	pub(super) history: bool,
	pub(super) suspended: bool,
	pub(super) note: DocumentText,
	pub(super) revoked: bool,
}

impl Grant {
	pub fn id(&self) -> &str {
		&self.id
	}
	pub fn label(&self) -> &DocumentText {
		&self.label
	}
	pub fn rights(&self) -> Rights {
		self.rights
	}
	pub fn history(&self) -> bool {
		self.history
	}
	pub fn suspended(&self) -> bool {
		self.suspended
	}
	pub fn note(&self) -> &DocumentText {
		&self.note
	}
	pub fn revoked(&self) -> bool {
		self.revoked
	}

	/// Consult this on each admitted operation. Holding an old projection does
	/// not preserve access after policy changes or revocation.
	pub fn access(&self) -> Access {
		if self.revoked || self.suspended {
			return Access::None;
		}
		match self.rights {
			Rights::Observe => Access::Observe,
			Rights::Interact => Access::Interact,
			Rights::Admin => Access::Admin,
		}
	}

	pub(super) fn validate(&self) -> Result<(), Error> {
		validate_id(&self.id)?;
		validate_label(self.label.utf16())?;
		validate_note(self.note.utf16())?;
		Ok(())
	}
}

pub(crate) fn validate_label(units: impl Iterator<Item = u16>) -> Result<(), Error> {
	let mut count = 0;
	let mut whitespace = true;
	for unit in units {
		count += 1;
		if count > MAX_GRANT_LABEL_UNITS {
			return Err(Error::InvalidGrant);
		}
		whitespace &= char::from_u32(u32::from(unit)).is_some_and(crate::text::js_whitespace);
	}
	if whitespace { Err(Error::InvalidGrant) } else { Ok(()) }
}
pub(super) fn validate_note(mut units: impl Iterator<Item = u16>) -> Result<(), Error> {
	if units.by_ref().take(MAX_GRANT_NOTE_UNITS + 1).count() > MAX_GRANT_NOTE_UNITS {
		Err(Error::InvalidGrant)
	} else {
		Ok(())
	}
}

pub(crate) fn validate_id(id: &str) -> Result<(), Error> {
	let bytes = id.as_bytes();
	if bytes.len() != 36 {
		return Err(Error::InvalidGrant);
	}
	for (i, b) in bytes.iter().enumerate() {
		let valid = match i {
			8 | 13 | 18 | 23 => *b == b'-',
			14 => *b == b'4',
			19 => matches!(b, b'8' | b'9' | b'a' | b'b'),
			_ => b.is_ascii_digit() || matches!(b, b'a'..=b'f'),
		};
		if !valid {
			return Err(Error::InvalidGrant);
		}
	}
	Ok(())
}

// ECMAScript TrimString uses this set, which differs from Rust's is_whitespace.

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PolicyPatch {
	pub rights: Option<Rights>,
	pub history: Option<bool>,
	pub suspended: Option<bool>,
	pub note: Option<DocumentText>,
}

#[derive(Clone, Debug)]
pub enum Command {
	Issue {
		id: String,
		rights: Rights,
		label: DocumentText,
		history: bool,
	},
	SetPolicy {
		id: String,
		patch: PolicyPatch,
	},
	Revoke {
		id: String,
	},
}

impl Command {
	/// Bound a local or decoded command before it enters a persistence queue.
	pub fn admit(self) -> Result<Self, Error> {
		Ok(match self {
			Self::Issue {
				id,
				rights,
				label,
				history,
			} => {
				validate_id(&id)?;
				validate_label(label.utf16())?;
				Self::Issue {
					id: id.into_boxed_str().into_string(),
					rights,
					label: label.compact(),
					history,
				}
			}
			Self::SetPolicy { id, mut patch } => {
				validate_id(&id).map_err(|_| Error::Missing)?;
				patch.note = if patch.suspended == Some(false) {
					None
				} else {
					patch
						.note
						.map(|note| {
							validate_note(note.utf16())?;
							Ok(note.compact())
						})
						.transpose()?
				};
				Self::SetPolicy {
					id: id.into_boxed_str().into_string(),
					patch,
				}
			}
			Self::Revoke { id } => Self::Revoke {
				id: if validate_id(&id).is_ok() {
					id.into_boxed_str().into_string()
				} else {
					String::new()
				},
			},
		})
	}
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Change {
	Issued,
	PolicyChanged,
	Revoked,
	Unchanged,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	MalformedDocument,
	UnsupportedVersion,
	InvalidGrant,
	DuplicateId,
	DocumentTooLarge,
	ActiveLimit,
	LifetimeLimit,
	Missing,
	Revoked,
	Conflict,
	RecoveryRequired,
	Busy,
	WrongOwner,
}

impl fmt::Display for Error {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		f.write_str(match self {
			Self::MalformedDocument => "Rooms grant document is malformed",
			Self::UnsupportedVersion => "Rooms grant document version is unsupported",
			Self::InvalidGrant => "Rooms grant is invalid",
			Self::DuplicateId => "Rooms grant document contains a repeated id",
			Self::DocumentTooLarge => "Rooms grant document exceeds its byte ceiling",
			Self::ActiveLimit => "Rooms session has too many active grants",
			Self::LifetimeLimit => "Rooms session has exhausted its durable grant ledger",
			Self::Missing => "Rooms grant id names no grant",
			Self::Revoked => "Rooms grant has been revoked and its id cannot be reused",
			Self::Conflict => "Rooms grant id already names a different grant",
			Self::Busy => "Rooms grant mutation is already in progress",
			Self::WrongOwner => "Rooms grant acknowledgement belongs to another ledger",
			Self::RecoveryRequired => "Rooms grant storage outcome is uncertain; restore before admitting operations",
		})
	}
}

impl core::error::Error for Error {}
