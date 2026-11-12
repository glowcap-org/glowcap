//! IRC numerics follow the canonical Rooms code, independent of its detail.
use rooms_application::failure::{Failure, FailureCode};

/// A refused IRC command: the catalog code that selects its numeric, and the
/// line the IRC client reads.
#[derive(Debug)]
pub(super) struct Refused {
	pub code: Option<FailureCode>,
	pub text: String,
}
/// A Rooms client error keeps its typed code. A refusal the other side
/// worded is read as it wrote it, without the binding's wrapper. A failure to
/// reach it has only binding diagnostics for text, so the line is the
/// catalog's sentence when the catalog names it.
impl From<rooms_glowcap::client::Error> for Refused {
	fn from(error: rooms_glowcap::client::Error) -> Self {
		use rooms_glowcap::client::Error;
		let code = error.failure_code();
		let worded = match &error {
			Error::Binding(binding) | Error::Unsent(binding) => binding.application_message().map(str::to_owned),
			other => Some(other.to_string()),
		};
		let text = match (code, worded) {
			// The remedy is this server's own flag, which the catalog cannot name.
			(Some(FailureCode::TransportNotDialed), _) => NOT_DIALED.to_owned(),
			(_, Some(worded)) => worded,
			(Some(code), None) => {
				let definition = code.definition();
				match definition.action {
					Some(action) => format!("{} {action}", definition.summary),
					None => definition.summary.to_owned(),
				}
			}
			(None, None) => error.to_string(),
		};
		Self { code, text }
	}
}
const NOT_DIALED: &str = "That member's address uses a transport this IRC server doesn't dial. Its operator can add it with --dial-transports.";
/// A refusal this server builds itself already holds its code.
impl From<Failure<'_>> for Refused {
	fn from(failure: Failure<'_>) -> Self {
		Self {
			code: Some(failure.code),
			text: failure.to_string(),
		}
	}
}
/// A line this server words itself is a diagnostic. It names no code, so
/// text a failed write or cleanup produced cannot choose a numeric.
impl From<String> for Refused {
	fn from(text: String) -> Self {
		Self { code: None, text }
	}
}
pub(super) fn registration(code: Option<FailureCode>) -> &'static str {
	match code {
		Some(FailureCode::NickTaken) => "433",
		_ => "400",
	}
}
pub(super) fn join(code: Option<FailureCode>) -> &'static str {
	match code {
		Some(FailureCode::NickTaken) => "433",
		Some(FailureCode::TooManyRooms) => "405",
		Some(FailureCode::RoomFull) => "471",
		_ => "403",
	}
}
pub(super) fn direct(code: Option<FailureCode>) -> &'static str {
	match code {
		Some(FailureCode::PeerOffline) => "401",
		Some(FailureCode::TooManyDirects) => "407",
		_ => "400",
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn a_member_this_server_cannot_dial_is_said_with_its_own_flag() {
		let undialed = glowcap::Error::transport_unavailable("no provider");
		let refused = Refused::from(rooms_glowcap::client::Error::Binding(Box::new(undialed)));
		assert_eq!(refused.code, Some(FailureCode::TransportNotDialed));
		assert_eq!(refused.text, NOT_DIALED);
	}

	fn worded(text: &str) -> Option<FailureCode> {
		Failure::parse(text).map(|failure| failure.code)
	}

	#[test]
	fn a_diagnostic_line_names_no_code_whatever_it_starts_with() {
		assert_eq!(
			Refused::from(String::from("nick-taken: socket write failed")).code,
			None
		);
		assert_eq!(Refused::from(FailureCode::TooManyDirects.line("at most 32")).code, None);
		let coded = Failure {
			code: FailureCode::TooManyDirects,
			detail: "at most 32",
		};
		assert_eq!(Refused::from(coded).code, Some(FailureCode::TooManyDirects));
	}

	#[test]
	fn numerics_follow_codes_and_ignore_misleading_detail() {
		assert_eq!(registration(worded("nick-taken: revised wording")), "433");
		assert_eq!(
			registration(worded("glowcap error -7: nick-taken: revised wording")),
			"400"
		);
		assert_eq!(registration(worded("unknown: nick-taken")), "400");
		assert_eq!(join(worded("nick-taken: revised wording")), "433");
		assert_eq!(join(worded("too-many-rooms: revised wording")), "405");
		assert_eq!(join(worded("room-full: revised wording")), "471");
		assert_eq!(join(worded("unknown: nick-taken")), "403");
		assert_eq!(direct(worded("peer-offline: revised wording")), "401");
		assert_eq!(direct(worded("too-many-directs: revised wording")), "407");
		assert_eq!(
			direct(worded("unknown: peer-offline, table is full, at most 32")),
			"400"
		);
	}
}
