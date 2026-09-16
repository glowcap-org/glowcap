//! Hosted Rooms files: one host-wide budget with independent room lifetimes.
//! Capability handles are minted here, never reconstructed from wire ids.
//! The owner drives mutations and time; reads borrow bytes until encoding ends.
mod failure;
pub mod identity;
mod line;
mod protocol;
mod read;
pub mod receiving;
pub mod sources;
mod store;
pub mod transfer;

use alloc::{
	rc::{Rc, Weak},
	string::String,
	vec::Vec,
};
use core::{
	cell::{Cell, RefCell},
	task::Waker,
};
pub use line::{FileLineError, HostedLine};
pub use protocol::{FileArgument, FileCallError};
pub use read::{ReadOutcome, ReadTicket};
pub use store::FileStore;

pub const CHUNK_BYTES: usize = 64 * 1024;
pub const MAX_FILE_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_FILE_NAME_UNITS: usize = 160;
pub const MAX_MIME_UNITS: usize = 80;
pub const MAX_IMAGE_DIMENSION: u32 = 65_535;
pub const UPLOAD_IDLE_MS: u64 = 30_000;
pub const MAX_BLOB_READERS: usize = 256;

/// Aggregate limits also bound zero-byte file metadata. The byte limits alone
/// cannot do that. Smaller limits are useful for constrained browser hosts.
#[derive(Clone, Copy, Debug)]
pub struct FileLimits {
	pub pending_bytes: usize,
	pub pending_files: usize,
	pub held_bytes: usize,
	pub held_files: usize,
	pub room_bytes: usize,
	pub room_files: usize,
}

impl Default for FileLimits {
	fn default() -> Self {
		Self {
			pending_bytes: 64 * 1024 * 1024,
			pending_files: 1024,
			held_bytes: 256 * 1024 * 1024,
			held_files: 4096,
			room_bytes: 64 * 1024 * 1024,
			room_files: 128,
		}
	}
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileDescription {
	name: String,
	mime: String,
	size: usize,
	width: u32,
	height: u32,
}

impl FileDescription {
	pub fn retained_bytes(&self) -> usize {
		self.name.capacity().saturating_add(self.mime.capacity())
	}
	pub fn new(name: String, mime: String, size: u64, width: u64, height: u64) -> Result<Self, FileError> {
		Self::validate(&name, &mime, size)?;
		Ok(Self::validated(name, mime, size, width, height))
	}
	/// Validate borrowed wire fields before allocating retained metadata.
	pub fn parse(name: &str, mime: &str, size: u64, width: u64, height: u64) -> Result<Self, FileError> {
		Self::validate(name, mime, size)?;
		Ok(Self::validated(name.into(), mime.into(), size, width, height))
	}
	fn validate(name: &str, mime: &str, size: u64) -> Result<(), FileError> {
		validate_description(
			name.encode_utf16().take(MAX_FILE_NAME_UNITS + 1).count(),
			mime.encode_utf16().take(MAX_MIME_UNITS + 1).count(),
			size,
		)
	}

	fn validated(name: String, mime: String, size: u64, width: u64, height: u64) -> Self {
		let pixels = |value| {
			if value <= u64::from(MAX_IMAGE_DIMENSION) {
				value as u32
			} else {
				0
			}
		};
		Self {
			name,
			mime,
			size: size as usize,
			width: pixels(width),
			height: pixels(height),
		}
	}
	pub fn name(&self) -> &str {
		&self.name
	}
	pub fn mime(&self) -> &str {
		&self.mime
	}
	pub fn size(&self) -> usize {
		self.size
	}
	pub fn dimensions(&self) -> (u32, u32) {
		(self.width, self.height)
	}
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FileError {
	Description,
	Size,
	Capacity,
	StagedLimit,
	Allocation,
	WrongStore,
	WrongRoom,
	Closed,
	Expired,
	Spent,
	NotPublished,
	ChunkTooLarge,
	PastEnd,
	InvalidRead,
	ReadersFull,
	ClockReversed,
	IdentityExhausted,
}

/// A scope token is held by the room owner. Dropping it immediately disables
/// its blobs; close_room additionally reclaims their storage in the same turn.
#[derive(Debug)]
pub struct FileRoom {
	key: Key,
	life: Rc<ScopeLife>,
}

/// One exact membership generation. Its pending uploads end with it; completed
/// posted files last until their room or line retires them.
#[derive(Debug)]
pub struct FileMember {
	key: Key,
	life: Rc<ScopeLife>,
	room: u64,
	room_life: Weak<ScopeLife>,
}

#[derive(Clone, Debug)]
struct Key {
	store: Rc<()>,
	id: u64,
}

#[derive(Debug)]
struct ScopeLife {
	active: Cell<bool>,
}

impl ScopeLife {
	fn new() -> Rc<Self> {
		Rc::new(Self {
			active: Cell::new(true),
		})
	}
}

fn scope_live(scope: &Weak<ScopeLife>) -> bool {
	scope.upgrade().is_some_and(|scope| scope.active.get())
}

#[derive(Clone, Debug)]
pub struct Blob {
	key: Key,
	room: u64,
	description: Rc<FileDescription>,
}

impl Blob {
	pub fn description(&self) -> &FileDescription {
		&self.description
	}
}

/// Write authority remains passable independently of the member that staged
/// it. The store retains the member generation that controls cancellation.
#[derive(Clone, Debug)]
pub struct Upload {
	blob: Blob,
}
impl Upload {
	pub fn blob(&self) -> Blob {
		self.blob.clone()
	}
}

/// The line's ownership, separate from the blob read capability. This cannot
/// be cloned. Dropping it disables every blob alias; retire reclaims promptly.
#[derive(Debug)]
pub struct HostedFile {
	blob: Blob,
	_owner: Rc<()>,
}

impl HostedFile {
	pub fn blob(&self) -> Blob {
		self.blob.clone()
	}
	pub fn description(&self) -> &FileDescription {
		self.blob.description()
	}
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct FileUsage {
	pub pending_bytes: usize,
	pub pending_files: usize,
	pub held_bytes: usize,
	pub held_files: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase {
	Staged,
	Streaming,
	Held,
}

struct Record {
	blob: Blob,
	room: u64,
	room_life: Weak<ScopeLife>,
	member: u64,
	member_life: Weak<ScopeLife>,
	owner: Option<Weak<()>>,
	phase: Phase,
	bytes: Vec<u8>,
	written: usize,
	deadline: u64,
	readers: Vec<Weak<ReaderWake>>,
}

struct ReaderWake {
	offset: usize,
	waker: RefCell<Option<Waker>>,
}

impl Record {
	fn live(&self) -> bool {
		scope_live(&self.room_life)
			&& (self.phase == Phase::Held || scope_live(&self.member_life))
			&& self.owner.as_ref().is_none_or(|owner| owner.strong_count() > 0)
	}
	fn wake(&mut self, terminal: bool) {
		self.readers.retain(|reader| {
			if let Some(reader) = reader.upgrade() {
				if terminal || reader.offset < self.written || self.written == self.bytes.len() {
					let waker = reader.waker.borrow_mut().take();
					if let Some(waker) = waker {
						waker.wake();
					}
					// This offset can never become pending again. The ticket may
					// remain alive, but it no longer spends a waiting-reader slot.
					return false;
				}
				true
			} else {
				false
			}
		});
		if terminal || self.written == self.bytes.len() {
			// Completed files never register readers again. Release the queue's
			// allocation instead of retaining it throughout held-media custody.
			self.readers = Vec::new();
		}
	}
}

impl Drop for Record {
	fn drop(&mut self) {
		self.wake(true);
	}
}

pub(crate) fn validate_description(name_units: usize, mime_units: usize, size: u64) -> Result<(), FileError> {
	if name_units == 0 || name_units > MAX_FILE_NAME_UNITS || mime_units > MAX_MIME_UNITS {
		return Err(FileError::Description);
	}
	if size > MAX_FILE_BYTES as u64 {
		return Err(FileError::Size);
	}
	Ok(())
}
