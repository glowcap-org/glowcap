//! Existing Rooms grant commands and JSON views, independent of CapTP values.
use super::{Access, Command, Error, Grant, PolicyPatch, Rights, model};
use crate::{room::ArgumentView, text::DocumentText};
use alloc::string::String;
use core::fmt;
use serde::{Deserialize, Serialize};

pub const ISSUE: &str = "issueGrant";
pub const SET_POLICY: &str = "setGrantPolicy";
pub const REVOKE: &str = "revokeGrant";
pub const MAX_GRANT_LINK_UNITS: usize = 16 * 1024;
pub const MAX_GRANT_VIEW_BYTES: usize =
	6 * (36 + super::MAX_GRANT_LABEL_UNITS + super::MAX_GRANT_NOTE_UNITS + MAX_GRANT_LINK_UNITS) + 256;

#[derive(Debug, PartialEq, Eq)]
pub enum Refusal {
	Access,
	Arguments,
	Capability,
	Policy(Error),
	View,
}
impl fmt::Display for Refusal {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::Access => f.write_str("this Rooms session facet cannot administer durable grants"),
			Self::Arguments => f.write_str("invalid Rooms grant command arguments"),
			Self::Capability => f.write_str("Rooms grant commands do not take capability arguments"),
			Self::Policy(e) => e.fmt(f),
			Self::View => f.write_str("invalid Rooms grant view"),
		}
	}
}
impl core::error::Error for Refusal {}

fn rights(value: &str) -> Result<Rights, Refusal> {
	match value {
		"observe" => Ok(Rights::Observe),
		"interact" => Ok(Rights::Interact),
		"admin" => Ok(Rights::Admin),
		_ => Err(Refusal::Arguments),
	}
}
fn label(value: &str) -> Result<DocumentText, Refusal> {
	model::validate_label(value.encode_utf16()).map_err(Refusal::Policy)?;
	Ok(value.into())
}

/// Unknown verbs remain with the enclosing session dispatcher. Recognized
/// commands reject nested capabilities before copying any retained arguments.
pub fn read<A: ArgumentView>(access: Access, verb: &str, args: &[A]) -> Option<Result<Command, Refusal>> {
	if !matches!(verb, ISSUE | SET_POLICY | REVOKE) {
		return None;
	}
	Some((|| {
		if args.iter().any(ArgumentView::contains_capability) {
			return Err(Refusal::Capability);
		}
		if access != Access::Admin {
			return Err(Refusal::Access);
		}
		let expected = match verb {
			ISSUE => 4,
			SET_POLICY => 5,
			_ => 1,
		};
		if args.len() != expected {
			return Err(Refusal::Arguments);
		}
		let id = args[0].text().ok_or(Refusal::Arguments)?;
		if verb == REVOKE {
			// Every retained id is a validated UUID. Unknown text is an idempotent
			// no-op; normalize it before queuing so it cannot choose queue memory.
			return Ok(Command::Revoke {
				id: if model::validate_id(id).is_ok() {
					id.into()
				} else {
					String::new()
				},
			});
		}
		if verb == ISSUE {
			model::validate_id(id).map_err(Refusal::Policy)?;
			return Ok(Command::Issue {
				id: id.into(),
				rights: rights(args[1].text().ok_or(Refusal::Arguments)?)?,
				label: label(args[2].text().ok_or(Refusal::Arguments)?)?,
				history: args[3].boolean().ok_or(Refusal::Arguments)?,
			});
		}
		let patch = PolicyPatch {
			rights: if args[1].is_null() {
				None
			} else {
				Some(rights(args[1].text().ok_or(Refusal::Arguments)?)?)
			},
			history: if args[2].is_null() {
				None
			} else {
				Some(args[2].boolean().ok_or(Refusal::Arguments)?)
			},
			suspended: if args[3].is_null() {
				None
			} else {
				Some(args[3].boolean().ok_or(Refusal::Arguments)?)
			},
			note: if args[4].is_null() {
				None
			} else {
				let note = args[4].text().ok_or(Refusal::Arguments)?;
				if args[3].boolean() == Some(false) {
					None
				} else {
					model::validate_note(note.encode_utf16()).map_err(Refusal::Policy)?;
					Some(note.into())
				}
			},
		};
		model::validate_id(id).map_err(|_| Refusal::Policy(Error::Missing))?;
		Ok(Command::SetPolicy { id: id.into(), patch })
	})())
}

/// A projection, never admission authority. Retained document text remains
/// lossless when encoded for a JavaScript client.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GrantView {
	pub id: String,
	pub label: DocumentText,
	pub rights: Rights,
	pub history: bool,
	pub suspended: bool,
	pub note: DocumentText,
	pub sturdyref: String,
}
impl GrantView {
	pub fn from_grant(grant: &Grant, sturdyref: String) -> Result<Self, Refusal> {
		if grant.revoked() {
			return Err(Refusal::Policy(Error::Revoked));
		}
		let value = Self {
			id: grant.id().into(),
			label: grant.label().clone(),
			rights: grant.rights(),
			history: grant.history(),
			suspended: grant.suspended(),
			note: grant.note().clone(),
			sturdyref,
		};
		value.validate()?;
		Ok(value)
	}
	pub(crate) fn validate(&self) -> Result<(), Refusal> {
		model::validate_id(&self.id).map_err(Refusal::Policy)?;
		model::validate_label(self.label.utf16()).map_err(Refusal::Policy)?;
		model::validate_note(self.note.utf16()).map_err(Refusal::Policy)?;
		if self.sturdyref.encode_utf16().take(MAX_GRANT_LINK_UNITS + 1).count() > MAX_GRANT_LINK_UNITS
			|| !self.sturdyref.starts_with("ocapn://")
			|| !self.sturdyref.contains("/s/")
		{
			return Err(Refusal::View);
		}
		Ok(())
	}
	pub fn encode(&self) -> Result<String, Refusal> {
		self.validate()?;
		serde_json::to_string(self).map_err(|_| Refusal::View)
	}
	pub fn decode(text: &str) -> Result<Self, Refusal> {
		// At most 36+80+200+16384 UTF-16 units, each escaped to six bytes,
		// plus fixed field names. A malformed peer cannot choose an unbounded
		// intermediate JSON allocation.
		if text.len() > MAX_GRANT_VIEW_BYTES {
			return Err(Refusal::View);
		}
		let value: Self = serde_json::from_str(text).map_err(|_| Refusal::View)?;
		value.validate()?;
		Ok(value)
	}
}
