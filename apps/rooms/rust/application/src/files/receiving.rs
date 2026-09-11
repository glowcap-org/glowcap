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
