//! Receiver custody shares the direct-file ceilings, independently of sender
//! custody. A completed materialization remains charged until its final lease.
use super::sources::{MAX_BYTES, MAX_READS, MAX_SOURCES};
use alloc::rc::Rc;
use core::cell::Cell;
/// Logical attachment size is bounded even when repeated capabilities share
/// their physical materialization and spend the receiver budget only once.
pub fn selection_fits<'a>(mut descriptions: impl Iterator<Item = &'a super::FileDescription>) -> bool {
	descriptions
		.try_fold((0_usize, 0_usize), |(count, bytes), file| {
			let bytes = bytes.checked_add(file.size())?;
			(count < crate::room::line::MAX_MESSAGE_FILES && bytes <= MAX_BYTES).then_some((count + 1, bytes))
		})
		.is_some()
}
#[derive(Clone, Copy, Default, Debug, PartialEq, Eq)]
pub struct Usage {
	pub files: usize,
	pub bytes: usize,
	pub active: usize,
}
#[derive(Default)]
pub struct Budget(Rc<Cell<Usage>>);
pub struct Charge {
	usage: Rc<Cell<Usage>>,
	bytes: usize,
	active: bool,
}
impl Budget {
	pub fn usage(&self) -> Usage {
		self.0.get()
	}
	/// Reclaimable custody excludes every pending capture and pinned reader.
	/// Preflight does not retire any unrelated file when admission must refuse.
	pub fn can_admit(&self, bytes: usize, reclaimable_files: usize, reclaimable_bytes: usize) -> bool {
		self.can_admit_many(1, bytes, reclaimable_files, reclaimable_bytes)
	}
	pub fn can_admit_many(
		&self,
		incoming: usize,
		bytes: usize,
		reclaimable_files: usize,
		reclaimable_bytes: usize,
	) -> bool {
		let usage = self.usage();
		let (Some(files), Some(held)) = (
			usage.files.checked_sub(reclaimable_files),
			usage.bytes.checked_sub(reclaimable_bytes),
		) else {
			return false;
		};
		incoming <= MAX_READS.saturating_sub(usage.active)
			&& incoming <= MAX_SOURCES.saturating_sub(files)
			&& bytes <= MAX_BYTES.saturating_sub(held)
	}
	pub fn reserve(&self, bytes: usize) -> Option<Charge> {
		if !self.can_admit(bytes, 0, 0) {
			return None;
		}
		let mut usage = self.usage();
		usage.files += 1;
		usage.bytes += bytes;
		usage.active += 1;
		self.0.set(usage);
		Some(Charge {
			usage: self.0.clone(),
			bytes,
			active: true,
		})
	}
}
impl Charge {
	pub fn captured(&mut self) {
		if self.active {
			let mut usage = self.usage.get();
			usage.active -= 1;
			self.usage.set(usage);
			self.active = false;
		}
	}
}
impl Drop for Charge {
	fn drop(&mut self) {
		self.captured();
		let mut usage = self.usage.get();
		usage.files -= 1;
		usage.bytes -= self.bytes;
		self.usage.set(usage);
	}
}

/// The type a received file's bytes are given when the browser holds them.
///
/// A shown file lives at a `blob:` URL in the page's origin, and a reader can
/// open any shown image in its own tab. An SVG opened that way is a document,
/// and a document carries script. Among the types the viewer shows or plays,
/// the XML ones are the documents, so those are held as plain bytes along
/// with everything a reader can only save; the rest keep the type an `<img>`
/// or `<video>` needs. The sender chose the type, so it is read as the
/// browser would: case-insensitive, with parameters such as a charset
/// ignored. The page's `media.ts` makes the same decision for bytes it holds
/// itself.
pub fn blob_type(mime: &str) -> &str {
	// Byte slices, because a sender's type may hold a multibyte character
	// where a str slice would have to land on a boundary.
	let essence = mime.split(';').next().unwrap_or("").trim().as_bytes();
	let starts = |prefix: &[u8]| essence.len() >= prefix.len() && essence[..prefix.len()].eq_ignore_ascii_case(prefix);
	let ends = |suffix: &[u8]| {
		essence.len() >= suffix.len() && essence[essence.len() - suffix.len()..].eq_ignore_ascii_case(suffix)
	};
	let shown = starts(b"image/") || starts(b"video/") || starts(b"audio/");
	if shown && !ends(b"+xml") {
		mime
	} else {
		"application/octet-stream"
	}
}

#[cfg(test)]
mod tests {
	use super::blob_type;

	#[test]
	fn a_type_a_browser_would_run_script_from_is_held_as_bytes() {
		for mime in [
			"image/svg+xml",
			"IMAGE/SVG+XML",
			"image/svg+xml; charset=utf-8",
			"text/html",
			"application/xhtml+xml",
			"text/xml",
			"application/xml",
			"image/custom+xml",
			"application/pdf",
			"",
		] {
			assert_eq!(blob_type(mime), "application/octet-stream", "{mime}");
		}
		for mime in ["image/png", "image/webp", "video/mp4", "audio/ogg"] {
			assert_eq!(blob_type(mime), mime);
		}
	}
}
