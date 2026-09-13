//! Admission of a room's optional retained conversation. Wire decoding stays
//! in the binding; malformed display rows are ignored without retaining caps.
use alloc::{string::String, vec::Vec};

/// The membership history verb returns at most the server's last 100 lines.
pub const MAX_LINES: usize = 100;
pub const MAX_BYTES: usize = 2 * 1024 * 1024;
pub use crate::protocol_data::HISTORY as VERB;

#[derive(Debug, PartialEq)]
pub struct Line {
	pub from: String,
	pub text: String,
	pub at: f64,
	pub previews: crate::open_graph::Selection,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	TooManyLines,
	TooManyBytes,
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::TooManyLines => "the room's history exceeds its line limit",
			Self::TooManyBytes => "the room's history exceeds its byte limit",
		})
	}
}
impl core::error::Error for Error {}

#[derive(Default)]
pub struct History {
	lines: Vec<Line>,
	bytes: usize,
}
impl History {
	/// Values are borrowed projections of the first three fields in a list
	/// row. Missing/wrong-kind fields use the established display defaults.
	/// Validate the aggregate before allocating either retained string.
	pub fn push(&mut self, from: Option<&str>, text: Option<&str>, at: Option<f64>) -> Result<(), Error> {
		self.push_with_previews(from, text, at, None)
	}
	pub fn push_with_previews(
		&mut self,
		from: Option<&str>,
		text: Option<&str>,
		at: Option<f64>,
		previews: Option<&str>,
	) -> Result<(), Error> {
		let from = from.unwrap_or("");
		if from.is_empty() {
			return Ok(());
		}
		if self.lines.len() == MAX_LINES {
			return Err(Error::TooManyLines);
		}
		let text = text.unwrap_or("");
		let previews = previews
			.and_then(|encoded| crate::open_graph::Selection::decode(text, encoded).ok())
			.unwrap_or_default();
		let bytes = core::mem::size_of::<Line>()
			.saturating_add(from.len())
			.saturating_add(text.len());
		let bytes = bytes.saturating_add(previews.retained_bytes());
		if bytes > MAX_BYTES.saturating_sub(self.bytes) {
			return Err(Error::TooManyBytes);
		}
		self.lines.push(Line {
			from: from.into(),
			text: text.into(),
			at: at.unwrap_or(0.0),
			previews,
		});
		self.bytes += bytes;
		Ok(())
	}
	pub fn into_lines(self) -> Vec<Line> {
		self.lines
	}
}
