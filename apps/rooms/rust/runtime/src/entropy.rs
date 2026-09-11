//! Cryptographic entropy and bounded workspace identifiers.
use rooms_application::session::checkpoint::reconciliation::Id;

#[derive(Clone, Copy, Debug)]
pub struct EntropyUnavailable;
impl std::fmt::Display for EntropyUnavailable {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		f.write_str("platform cryptographic entropy is unavailable")
	}
}
impl std::error::Error for EntropyUnavailable {}

/// Platform cryptographic entropy. The caller owns this source; cloning a
/// runtime handle must not duplicate a generator state.
pub trait Entropy {
	fn fill(&mut self, bytes: &mut [u8]) -> Result<(), EntropyUnavailable>;
}

/// Draw a fresh identifier without copying or cloning the entropy source.
pub fn random_id(source: &mut dyn Entropy, prefix: &str) -> Result<Id, String> {
	if !Id::accepts_utf16(prefix.encode_utf16().chain(std::iter::repeat_n(u16::from(b'0'), 32))) {
		return Err("session identifier exceeds its field bound".into());
	}
	let mut entropy = [0; 16];
	source
		.fill(&mut entropy)
		.map_err(|_| "session identifier entropy is unavailable")?;
	use std::fmt::Write;
	let mut id = String::with_capacity(prefix.len() + 32);
	id.push_str(prefix);
	for byte in entropy {
		write!(&mut id, "{byte:02x}").expect("string formatting");
	}
	Id::new(id.into()).ok_or_else(|| "session identifier exceeds its field bound".into())
}
