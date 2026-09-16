//! Opt-in delivery of a retained post. The receipt occupies the post's normal
//! inbox position; it does not replace acknowledgement or line authority.
use super::{
	attachment::{self, Attachment, AttachmentArgument},
	inbox,
	line::MAX_LINE_BYTES,
	message::LineId,
};
use alloc::vec::Vec;

pub const POST: &str = "postRetained";
pub const POST_FILES: &str = "postFilesRetained";
pub const ATTACH: &str = "attachRetained";
pub const TAG: &str = "receipt";
pub const REJECTED: &str = "receiptRejected";
pub const MAX_REQUEST: u64 = (1 << 53) - 1;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	Malformed,
	Unknown,
	InvalidRequest,
	Exhausted,
	Full,
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Malformed => "invalid room receipt",
			Self::Unknown => "room receipt has no retained request",
			Self::InvalidRequest => "invalid or reused room receipt request",
			Self::Exhausted => "room receipt identifiers exhausted",
			Self::Full => "room retained message backlog is full",
		})
	}
}
impl core::error::Error for Error {}

pub fn request(value: i128) -> Option<u64> {
	(0..=MAX_REQUEST as i128).contains(&value).then_some(value as u64)
}

pub struct Receipt<'a, C> {
	pub request: u64,
	pub line: LineId,
	pub from: &'a str,
	/// Only a server-normalized caption is sent back; false retains local text.
	pub text: Option<&'a str>,
	pub attachments: Vec<Attachment<C>>,
	pub previews: &'a str,
}

pub fn read<A: AttachmentArgument>(args: &[A]) -> Result<Receipt<'_, A::Capability>, Error> {
	let invalid = Error::Malformed;
	let token = args
		.first()
		.and_then(|v| v.integer())
		.and_then(request)
		.ok_or(invalid)?;
	let line = args
		.get(1)
		.and_then(|v| v.integer())
		.and_then(request)
		.and_then(LineId::new)
		.ok_or(invalid)?;
	let from = args
		.get(2)
		.and_then(|v| v.text())
		.filter(|v| inbox::valid_nick(v))
		.ok_or(invalid)?;
	let text = match args.get(3) {
		Some(v) if v.boolean() == Some(false) => None,
		Some(v) => Some(v.text().filter(|v| v.len() <= MAX_LINE_BYTES).ok_or(invalid)?),
		None => return Err(invalid),
	};
	let previews = match args.get(4) {
		Some(v) if v.boolean() == Some(false) => "[]",
		Some(v) => v.text().ok_or(invalid)?,
		None => return Err(invalid),
	};
	let attachments = attachment::read_exact(args, 5).map_err(|_| invalid)?;
	Ok(Receipt {
		request: token,
		line,
		from,
		text,
		attachments,
		previews,
	})
}
