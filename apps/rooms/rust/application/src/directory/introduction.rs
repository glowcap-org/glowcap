//! Bounds and validation for one directory introduction.

pub use crate::protocol_data::INTRODUCE;
pub const MAX_OUTSTANDING: usize = 256;
pub const WAIT_MS: u64 = 10_000;
/// One introduction includes the server's offer wait and the ordinary request
/// budget for redemption, including signaling and a fallback route.
pub const REQUEST_TIMEOUT_MS: u64 = WAIT_MS + crate::room::authority::REQUEST_TIMEOUT_MS;
const _: () = assert!(REQUEST_TIMEOUT_MS - WAIT_MS > crate::signaling::TIMEOUT_MS);

/// A descriptive identity never confers authority. The held registration does.
pub fn valid_opening(value: &str) -> bool {
	crate::fields::Text::<128, true>::accepts_utf16(value.encode_utf16())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	Full,
	Ended,
	Capability,
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Full => "the directory has too many direct introductions in progress",
			Self::Ended => "the directory connection ended",
			Self::Capability => "the directory did not return a direct inbox capability",
		})
	}
}
impl core::error::Error for Error {}
