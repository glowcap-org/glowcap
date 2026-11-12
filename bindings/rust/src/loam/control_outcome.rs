//! Admission verdicts from a held management control, separate from breaks.
use crate::{Argument, Result};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ControlConflict {
	Revision,
	Operation,
}
impl ControlConflict {
	/// Read only the management protocol's explicit verdict. Ordinary replies
	/// return None; a malformed verdict refuses decoding.
	pub fn read(reply: &Argument) -> Result<Option<Self>> {
		let Argument::Tagged { tag, value } = reply else {
			return Ok(None);
		};
		if tag != "access:control-conflict" {
			return Ok(None);
		}
		match value.as_slice() {
			[Argument::Symbol(kind)] if kind == "revision" => Ok(Some(Self::Revision)),
			[Argument::Symbol(kind)] if kind == "operation" => Ok(Some(Self::Operation)),
			_ => Err(super::refusal("malformed control conflict verdict")),
		}
	}
}
impl std::fmt::Display for ControlConflict {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		f.write_str(match self {
			Self::Revision => "RevisionConflict",
			Self::Operation => "OperationConflict",
		})
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn only_an_explicit_control_verdict_is_a_conflict() {
		for text in ["RevisionConflict", "OperationConflict"] {
			assert_eq!(ControlConflict::read(&Argument::String(text.into())).unwrap(), None);
		}
		let verdict = |kind: &str| Argument::Tagged {
			tag: "access:control-conflict".into(),
			value: vec![Argument::Symbol(kind.into())],
		};
		assert_eq!(
			ControlConflict::read(&verdict("revision")).unwrap(),
			Some(ControlConflict::Revision)
		);
		assert_eq!(
			ControlConflict::read(&verdict("operation")).unwrap(),
			Some(ControlConflict::Operation)
		);
		assert!(ControlConflict::read(&verdict("unknown")).is_err());
	}
}
