//! Sender-held direct files. One owner spans conversations; expired in-flight
//! reads stay charged until their leases drop. No I/O or task ownership lives here.
use super::{CHUNK_BYTES, FileArgument, FileDescription};
use crate::room::line::MAX_MESSAGE_FILES;
use alloc::{collections::VecDeque, rc::Rc, vec::Vec};
use core::{
	cell::{Cell, RefCell},
	ops::Range,
};
mod read;
pub use read::Read;
pub const MAX_SOURCES: usize = 128;
pub const MAX_BYTES: usize = 64 * 1024 * 1024;
pub const MAX_READS: usize = 32;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	Files,
	Bytes,
	Capacity,
	Expired,
	Reads,
	Arguments,
	Reply,
	Source,
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Files => "a message may carry at most eight files",
			Self::Bytes => "direct files may total at most 64 MiB",
			Self::Capacity => "in-flight direct reads hold the source budget",
			Self::Expired => "the source is no longer held by its sender",
			Self::Reads => "too many direct file reads are active",
			Self::Arguments => "read needs a nonnegative integer offset and positive integer length",
			Self::Reply => "the source did not return the requested bytes",
			Self::Source => "the source does not match its declared size",
		})
	}
}
impl core::error::Error for Error {}
struct Slot<S> {
	description: FileDescription,
	source: RefCell<Option<Rc<S>>>,
	reads: Cell<usize>,
	prefix: Cell<usize>,
}
/// An issued blob occurrence cannot be retargeted or revived after expiration.
/// Holding metadata alone does not keep the backing source alive.
pub struct Blob<S> {
	slot: Rc<Slot<S>>,
	reads: Rc<Cell<usize>>,
}
impl<S> Clone for Blob<S> {
	fn clone(&self) -> Self {
		Self {
			slot: self.slot.clone(),
			reads: self.reads.clone(),
		}
	}
}
impl<S> Blob<S> {
	pub fn description(&self) -> &FileDescription {
		&self.slot.description
	}
	pub fn expire(&self) {
		self.slot.source.borrow_mut().take();
	}
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Usage {
	pub files: usize,
	pub bytes: usize,
	pub reads: usize,
}
/// The application runtime owns one pool. Blob and read handles cannot extend
/// its lifetime; dropping it expires every still-published backing source.
pub struct Sources<S> {
	rows: VecDeque<Rc<Slot<S>>>,
	reads: Rc<Cell<usize>>,
}
impl<S> Default for Sources<S> {
	fn default() -> Self {
		Self {
			rows: VecDeque::new(),
			reads: Rc::new(Cell::new(0)),
		}
	}
}
impl<S> Sources<S> {
	fn collect(&mut self) {
		self.rows
			.retain(|row| (row.source.borrow().is_some() && Rc::strong_count(row) > 1) || row.reads.get() > 0);
	}
	pub fn usage(&mut self) -> Usage {
		self.collect();
		Usage {
			files: self.rows.len(),
			bytes: self.rows.iter().map(|r| r.description.size()).sum(),
			reads: self.reads.get(),
		}
	}
	/// Validate the whole batch before expiring or publishing any source. S is
	/// already a validated platform backing source; nonempty inputs require one.
	pub fn retain(&mut self, sources: Vec<(FileDescription, S)>) -> Result<Vec<Blob<S>>, Error> {
		if sources.len() > MAX_MESSAGE_FILES {
			return Err(Error::Files);
		}
		let bytes: usize = sources.iter().map(|(d, _)| d.size()).sum();
		if bytes > MAX_BYTES {
			return Err(Error::Bytes);
		}
		let files = sources.iter().filter(|(d, _)| d.size() > 0).count();
		self.collect();
		// Preflight pinned pressure so a refusal cannot expire unrelated sources.
		let (pinned_files, pinned_bytes) = self
			.rows
			.iter()
			.filter(|r| r.reads.get() > 0)
			.fold((0, 0), |(files, bytes), row| {
				(files + 1, bytes + row.description.size())
			});
		if pinned_files + files > MAX_SOURCES || pinned_bytes + bytes > MAX_BYTES {
			return Err(Error::Capacity);
		}
		let mut usage = self.usage();
		while usage.files + files > MAX_SOURCES || usage.bytes + bytes > MAX_BYTES {
			let row = self
				.rows
				.iter()
				.find(|r| r.source.borrow().is_some())
				.expect("preflight found reclaimable sources");
			row.source.borrow_mut().take();
			usage = self.usage();
		}
		Ok(sources
			.into_iter()
			.map(|(description, source)| {
				let nonempty = description.size() > 0;
				let slot = Rc::new(Slot {
					description,
					source: RefCell::new(if nonempty { Some(Rc::new(source)) } else { None }),
					reads: Cell::new(0),
					prefix: Cell::new(0),
				});
				if nonempty {
					self.rows.push_back(slot.clone());
				}
				Blob {
					slot,
					reads: self.reads.clone(),
				}
			})
			.collect())
	}
}
impl<S> Drop for Sources<S> {
	fn drop(&mut self) {
		for row in &self.rows {
			row.source.borrow_mut().take();
		}
	}
}
