//! Shared rooms CLI helpers mirrored from `deno/lib/errors.ts`.

pub const NO_SUCH_ROOM: &str = "no-such-room";
pub const ROOM_EXISTS: &str = "room-exists";

/// The typed code at the front of a room error reason, `<code>: <detail>`.
pub fn error_code(reason: &str) -> &str {
	reason.split_once(": ").map_or("", |(code, _)| code)
}
