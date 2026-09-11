//! The four independently owned durable documents of a Rooms session.
use core::{fmt, str};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionDocument {
	Checkpoint,
	Effects,
	Grants,
	BridgeSecrets,
}

impl SessionDocument {
	pub const fn key(self) -> &'static str {
		match self {
			Self::Checkpoint => "checkpoint",
			Self::Effects => "effects",
			Self::Grants => "grants",
			Self::BridgeSecrets => "bridge-secrets",
		}
	}
	pub const fn max_bytes(self) -> usize {
		match self {
			Self::Checkpoint | Self::BridgeSecrets => 768 * 1024,
			Self::Effects => 4 * 1024 * 1024,
			Self::Grants => 128 * 1024,
		}
	}
	/// Like the existing TextDecoder, accept a leading UTF-8 BOM. Absence is
	/// represented by the storage adapter, never by accepting a corrupt document.
	pub fn decode(self, bytes: &[u8]) -> Result<&str, DocumentError> {
		if bytes.len() > self.max_bytes() {
			return Err(DocumentError::TooLarge);
		}
		let text = str::from_utf8(bytes).map_err(|_| DocumentError::Utf8)?;
		Ok(text.strip_prefix('\u{feff}').unwrap_or(text))
	}
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DocumentError {
	TooLarge,
	Utf8,
}

impl fmt::Display for DocumentError {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		f.write_str(match self {
			Self::TooLarge => "document exceeds its byte ceiling",
			Self::Utf8 => "document is not UTF-8 text",
		})
	}
}
impl core::error::Error for DocumentError {}

/// The outcome of atomically replacing the document. An adapter may
/// report Unchanged only when it knows the stored document did not change.
#[derive(Debug, PartialEq, Eq)]
pub enum WriteFailure<E> {
	Unchanged(E),
	Indeterminate(E),
}
