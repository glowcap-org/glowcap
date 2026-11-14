//! Rooms attachment records shared by room and direct-message senders and
//! recipients. `append` writes one record in the order `record` reads it.
//! Decoding borrows binding values and retains only admitted capabilities.
use super::{ArgumentView, DataEncoder, line::MAX_MESSAGE_FILES};
use crate::files::{FileDescription, MAX_FILE_BYTES};
use alloc::vec::Vec;

pub const RECORD_SPAN: usize = 7;

pub trait AttachmentArgument: ArgumentView {
	/// Cloning retains the existing capability guard. It must never perform a
	/// new lookup from a displayed id or recreate retired authority.
	type Capability: Clone;
	fn capability(&self) -> Option<&Self::Capability>;
}

#[derive(Clone, Debug)]
pub struct Attachment<C> {
	pub description: FileDescription,
	pub blob: C,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AttachmentError {
	IncompleteRecords,
	TooManyFiles,
	MalformedRecord,
}

/// Append one attachment record in the field order `record` reads. The caller
/// supplies the capability already encoded, so each side mints its own.
pub fn append<E: DataEncoder>(e: &mut E, description: &FileDescription, blob: E::Value, out: &mut Vec<E::Value>) {
	let (width, height) = description.dimensions();
	out.push(e.text("file".into()));
	out.push(e.text(description.name().into()));
	out.push(e.text(description.mime().into()));
	out.push(e.integer(description.size() as u64));
	out.push(blob);
	out.push(e.integer(width.into()));
	out.push(e.integer(height.into()));
}

/// Display accepts a valid prefix and stops at the first malformed record or
/// the file cap. A hostile suffix cannot erase the text and valid files before
/// it. Every argument remains in the binding's custody until its call ends.
pub fn read_prefix<A: AttachmentArgument>(args: &[A], start: usize) -> Vec<Attachment<A::Capability>> {
	read_prefix_with_end(args, start).0
}

/// Also return the first field after the accepted record prefix so an additive
/// message extension can be decoded without scanning or reinterpreting files.
pub fn read_prefix_with_end<A: AttachmentArgument>(
	args: &[A],
	start: usize,
) -> (Vec<Attachment<A::Capability>>, usize) {
	let mut files = Vec::new();
	let mut at = start;
	while files.len() < MAX_MESSAGE_FILES {
		let Some(file) = record(args, at) else {
			break;
		};
		files.push(file);
		let Some(next) = at.checked_add(RECORD_SPAN) else {
			break;
		};
		at = next;
	}
	(files, at)
}

/// State-changing calls require a complete record suffix. On refusal, all
/// tentative capability retains are dropped before the error is returned.
pub fn read_exact<A: AttachmentArgument>(
	args: &[A],
	start: usize,
) -> Result<Vec<Attachment<A::Capability>>, AttachmentError> {
	let remaining = args
		.len()
		.checked_sub(start)
		.ok_or(AttachmentError::IncompleteRecords)?;
	if remaining % RECORD_SPAN != 0 {
		return Err(AttachmentError::IncompleteRecords);
	}
	if remaining / RECORD_SPAN > MAX_MESSAGE_FILES {
		return Err(AttachmentError::TooManyFiles);
	}
	(start..args.len())
		.step_by(RECORD_SPAN)
		.map(|at| record(args, at).ok_or(AttachmentError::MalformedRecord))
		.collect()
}

fn record<A: AttachmentArgument>(args: &[A], at: usize) -> Option<Attachment<A::Capability>> {
	let args = args.get(at..)?;
	if args.first()?.text()? != "file" {
		return None;
	}
	let name = args.get(1)?.text()?;
	let mime = args.get(2)?.text()?;
	let size = args.get(3)?.integer()?;
	if !(0..=MAX_FILE_BYTES as i128).contains(&size) {
		return None;
	}
	let blob = args.get(4)?.capability()?;
	let pixels = |at: usize| u64::try_from(args.get(at)?.integer()?).ok();
	let description = FileDescription::parse(name, mime, size as u64, pixels(5)?, pixels(6)?).ok()?;
	Some(Attachment {
		description,
		blob: blob.clone(),
	})
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::room::test_value::{Value, ValueEncoder};

	#[test]
	fn appended_records_read_back_as_the_same_attachments() {
		let png = FileDescription::parse("cat.png", "image/png", 1234, 640, 480).unwrap();
		let text = FileDescription::parse("a.txt", "text/plain", 3, 0, 0).unwrap();
		let mut args = Vec::new();
		append(&mut ValueEncoder, &png, Value::Capability(9), &mut args);
		append(&mut ValueEncoder, &text, Value::Capability(4), &mut args);
		assert_eq!(args.len(), 2 * RECORD_SPAN);
		let read = read_exact(&args, 0).unwrap();
		assert_eq!(read.len(), 2);
		assert_eq!((&read[0].description, read[0].blob), (&png, 9));
		assert_eq!((&read[1].description, read[1].blob), (&text, 4));
	}
}
