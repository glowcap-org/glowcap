//! IRC numerics follow the canonical Rooms code, independent of its detail.
use rooms_application::failure::{Failure, FailureCode};

fn code(reason: &str) -> Option<FailureCode> {
	Failure::parse(reason).map(|failure| failure.code)
}
pub(super) fn registration(reason: &str) -> &'static str {
	match code(reason) {
		Some(FailureCode::NickTaken) => "433",
		_ => "400",
	}
}
pub(super) fn join(reason: &str) -> &'static str {
	match code(reason) {
		Some(FailureCode::NickTaken) => "433",
		Some(FailureCode::TooManyRooms) => "405",
		Some(FailureCode::RoomFull) => "471",
		_ => "403",
	}
}
pub(super) fn direct(reason: &str) -> &'static str {
	match code(reason) {
		Some(FailureCode::PeerOffline) => "401",
		Some(FailureCode::TooManyDirects) => "407",
		_ => "400",
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn numerics_follow_codes_and_ignore_misleading_detail() {
		assert_eq!(registration("nick-taken: revised wording"), "433");
		assert_eq!(registration("glowcap error -7: nick-taken: revised wording"), "433");
		assert_eq!(registration("unknown: nick-taken"), "400");
		assert_eq!(join("nick-taken: revised wording"), "433");
		assert_eq!(join("too-many-rooms: revised wording"), "405");
		assert_eq!(join("room-full: revised wording"), "471");
		assert_eq!(join("unknown: nick-taken"), "403");
		assert_eq!(direct("peer-offline: revised wording"), "401");
		assert_eq!(direct("too-many-directs: revised wording"), "407");
		assert_eq!(direct("unknown: peer-offline, table is full, at most 32"), "400");
	}
}
