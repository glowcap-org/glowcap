//! IRC presentation of Rooms. Names here are reversible display aliases.
//! Possession of the Rooms capability remains the authority to act.
mod names;
use super::protocol::{self, Error};
use alloc::{format, string::String, vec::Vec};
pub use names::{Names, channel, room_name};
pub const CLIENTS: usize = 256;
pub const ROOMS: usize = 32;
pub const DIRECTS: usize = 32;
pub const PROJECTED_NAMES: usize = 2048;

pub fn member_prefix(nick: &str, server: &str) -> String {
	format!("{nick}!rooms@{server}")
}
/// Shorten explanatory text on a UTF-8 boundary. Never shorten chat content.
/// The fixed frame overhead is measured once by the authoritative encoder.
pub fn explanation(command: &str, leading: &[&str], prefix: &str, text: &str) -> Result<Vec<u8>, Error> {
	let safe: String = text.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
	let mut params = leading.to_vec();
	params.push(&safe);
	match protocol::encode_message(command, &params, Some(prefix)) {
		Err(Error::TooLong) => {}
		result => return result,
	}
	const MARKER: &str = " … [IRC line limit]";
	params.pop();
	params.push(MARKER);
	let overhead = protocol::encode_message(command, &params, Some(prefix))?.len();
	let limit = protocol::LINE_BYTES - overhead;
	let head: String = safe
		.char_indices()
		.take_while(|&(at, c)| at + c.len_utf8() <= limit)
		.map(|(_, c)| c)
		.collect();
	let shortened = format!("{head}{MARKER}");
	params.pop();
	params.push(&shortened);
	protocol::encode_message(command, &params, Some(prefix))
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn names_keep_the_clients_identity_and_reverse_foreign_aliases() {
		let mut names = Names::new("[alice]").unwrap();
		let other = names.project("{alice}").unwrap();
		assert_ne!(protocol::fold(&other), protocol::fold("[alice]"));
		assert_eq!(names.original(&other), "{alice}");
		assert_eq!(names.original("[ALICE]"), "[alice]");
		assert_eq!(names.project("{ALICE}").unwrap(), other);
	}
	#[test]
	fn explanation_truncation_keeps_utf8_and_frame_limits() {
		let bytes = explanation("NOTICE", &["alice"], "rooms.test", &"🌻".repeat(500)).unwrap();
		assert!(bytes.len() <= protocol::LINE_BYTES);
		let text = core::str::from_utf8(&bytes[..bytes.len() - 2]).unwrap();
		let parsed = protocol::parse_line(text).unwrap();
		assert!(parsed.last().unwrap().ends_with("[IRC line limit]"));
		assert_eq!(channel("#news").as_deref(), Some("##news"));
		assert!(channel("a room with spaces").is_none());
	}
}
