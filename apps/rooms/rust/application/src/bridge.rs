//! Bridge declarations decide which answers may be remembered. Platform
//! adapters carry forms and submissions without owning that policy.
use crate::text::DocumentText;

mod answers;
mod form;
pub mod gateway;
mod submission;
pub use answers::{Answers, Id};
pub use form::{Action, Confirm, Field, Form, Leaf, LeafRef, SecretField, TextField, TextOptions, ToggleField, Tone};
pub use submission::Submission;

pub const ASK: &str = "bridgeForm";
pub const SUBMIT: &str = "submitBridgeForm";
pub const MAX_JSON: usize = 16 * 1024;
pub const MAX_FIELDS: usize = 8;
pub const MAX_ACTIONS: usize = 3;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
	Form,
	Json,
	Size,
	Answers,
	Action,
	Required(DocumentText),
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Form => "the room answered an invalid bridge form",
			Self::Json => "the bridge form or answers are not valid JSON",
			Self::Size => "bridge form JSON is too long",
			Self::Answers => "bridge form answers are not valid",
			Self::Action => "the bridge form has no such action",
			Self::Required(label) => return write!(f, "{} is required.", label.utf8_lossy()),
		})
	}
}
impl core::error::Error for Error {}

pub fn read_form(reply: &impl crate::room::ArgumentView) -> Result<Option<Form>, Error> {
	if reply.is_null() || reply.text() == Some("") {
		return Ok(None);
	}
	Form::decode(reply.text().ok_or(Error::Form)?).map(Some)
}

fn check_size(raw: &str) -> Result<(), Error> {
	if raw.encode_utf16().take(MAX_JSON + 1).count() > MAX_JSON {
		Err(Error::Size)
	} else {
		Ok(())
	}
}
