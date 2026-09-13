//! Why a server verb says no. Every server policy answers refusals in this
//! one shape, so a client parses one form and the failure module is the
//! one authority for how a coded refusal reads on the wire.
use crate::failure::{Failure, FailureCode};
use alloc::string::{String, ToString};
use core::fmt;

/// A refusal the caller hears as a break. One with a Rooms failure code is
/// a condition a client acts on, rendered the way `Failure` renders it; a
/// plain one is a malformed or over-limit call, or the operator's own
/// mistake, read as text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
	pub code: Option<FailureCode>,
	pub detail: String,
}

impl Refusal {
	pub fn coded(code: FailureCode, detail: impl Into<String>) -> Self {
		Self {
			code: Some(code),
			detail: detail.into(),
		}
	}
	/// A refusal read as text. The detail is formatted here, so a policy
	/// hands an error value straight through; formatting an already owned
	/// `String` copies it once, on a refusal path only.
	/// A listener transport this build cannot realize, or an option it cannot
	/// honor: the one refusal the operations pane draws as a disabled seat.
	pub fn unsupported(detail: impl Into<String>) -> Self {
		Self::coded(FailureCode::ListenerUnsupported, detail)
	}
	pub fn plain(detail: impl fmt::Display) -> Self {
		Self {
			code: None,
			detail: detail.to_string(),
		}
	}
	/// The refusal's text without its code.
	pub fn detail(&self) -> &str {
		&self.detail
	}
	/// The break reason: `code: detail`, or the detail alone.
	pub fn reason(&self) -> String {
		self.to_string()
	}
}

impl fmt::Display for Refusal {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self.code {
			Some(code) => Failure {
				code,
				detail: &self.detail,
			}
			.fmt(f),
			None => f.write_str(&self.detail),
		}
	}
}

/// The break reason a caller hears.
impl From<Refusal> for String {
	fn from(refusal: Refusal) -> Self {
		refusal.reason()
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn a_coded_refusal_reads_the_way_a_failure_does() {
		let coded = Refusal::coded(FailureCode::NickTaken, "alice");
		assert_eq!(coded.reason(), "nick-taken: alice");
		assert_eq!(
			Failure::parse(&coded.reason()).map(|f| f.code),
			Some(FailureCode::NickTaken)
		);
		assert_eq!(coded.detail(), "alice");
		let plain = Refusal::plain(alloc::format!("{} bytes", 3));
		assert_eq!(String::from(plain), "3 bytes");
	}
}
