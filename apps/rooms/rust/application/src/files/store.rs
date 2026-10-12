//! The in-memory file store owns bounded sources and their expiry.
use super::*;
use crate::room::line::MAX_MESSAGE_FILES;
use alloc::collections::{BTreeMap, VecDeque};

pub struct FileStore {
	pub(super) identity: Rc<()>,
	next_id: u64,
	retirements: u64,
	now: u64,
	limits: FileLimits,
	pub(super) records: BTreeMap<u64, Record>,
	held: VecDeque<u64>,
	usage: FileUsage,
}

impl Default for FileStore {
	fn default() -> Self {
		Self::new(FileLimits::default())
	}
}

impl FileStore {
	/// Adapter-held reader identities cannot extend the file's storage lease.
	pub fn contains(&self, blob: &Blob) -> bool {
		self.check(&blob.key).is_ok() && self.records.get(&blob.key.id).is_some_and(Record::live)
	}
	/// An adapter key is meaningful only in this exact store instance.
	pub fn blob_id(&self, blob: &Blob) -> Option<u64> {
		self.check(&blob.key).is_ok().then_some(blob.key.id)
	}
	/// Capability inventories sweep only after storage identities retire.
	pub fn retirements(&self) -> u64 {
		self.retirements
	}
	pub fn new(limits: FileLimits) -> Self {
		Self {
			identity: Rc::new(()),
			next_id: 0,
			retirements: 0,
			now: 0,
			limits,
			records: BTreeMap::new(),
			held: VecDeque::new(),
			usage: FileUsage::default(),
		}
	}
	fn key(&mut self) -> Result<Key, FileError> {
		self.next_id = self.next_id.checked_add(1).ok_or(FileError::IdentityExhausted)?;
		Ok(Key {
			store: self.identity.clone(),
			id: self.next_id,
		})
	}
	pub(super) fn check(&self, key: &Key) -> Result<(), FileError> {
		if Rc::ptr_eq(&self.identity, &key.store) {
			Ok(())
		} else {
			Err(FileError::WrongStore)
		}
	}
	pub fn room(&mut self) -> Result<FileRoom, FileError> {
		Ok(FileRoom {
			key: self.key()?,
			life: ScopeLife::new(),
		})
	}
	pub fn member(&mut self, room: &FileRoom) -> Result<FileMember, FileError> {
		self.check(&room.key)?;
		if !room.life.active.get() {
			return Err(FileError::Closed);
		}
		Ok(FileMember {
			key: self.key()?,
			life: ScopeLife::new(),
			room: room.key.id,
			room_life: Rc::downgrade(&room.life),
		})
	}
	pub fn usage(&self) -> FileUsage {
		self.usage
	}
	pub fn room_usage(&self, room: &FileRoom) -> Result<FileUsage, FileError> {
		self.check(&room.key)?;
		let mut usage = FileUsage::default();
		for record in self.records.values().filter(|r| r.room == room.key.id) {
			if record.phase == Phase::Held {
				usage.held_files += 1;
				usage.held_bytes += record.bytes.len();
			} else {
				usage.pending_files += 1;
				usage.pending_bytes += record.bytes.len();
			}
		}
		Ok(usage)
	}

	/// Reserve before allocation. Failure leaves every existing upload intact.
	/// Allocation is one owned buffer per upload. Write copies each
	/// incoming chunk into that buffer once, and reads borrow it for encoding.
	pub fn attach(&mut self, member: &FileMember, description: FileDescription) -> Result<Upload, FileError> {
		self.check(&member.key)?;
		self.collect();
		if !member.life.active.get() || !scope_live(&member.room_life) {
			return Err(FileError::Closed);
		}
		if self.staged_count(member)? >= MAX_MESSAGE_FILES {
			return Err(FileError::StagedLimit);
		}
		let size = description.size;
		if self.usage.pending_files >= self.limits.pending_files
			|| size > self.limits.pending_bytes.saturating_sub(self.usage.pending_bytes)
			|| size > self.limits.held_bytes
			|| size > self.limits.room_bytes
			|| self.limits.held_files == 0
			|| self.limits.room_files == 0
		{
			return Err(FileError::Capacity);
		}
		let mut bytes = Vec::new();
		bytes.try_reserve_exact(size).map_err(|_| FileError::Allocation)?;
		bytes.resize(size, 0);
		let blob = Blob {
			key: self.key()?,
			room: member.room,
			description: Rc::new(description),
		};
		self.records.insert(
			blob.key.id,
			Record {
				blob: blob.clone(),
				room: member.room,
				room_life: member.room_life.clone(),
				member: member.key.id,
				member_life: Rc::downgrade(&member.life),
				owner: None,
				phase: Phase::Staged,
				bytes,
				written: 0,
				deadline: self.now.saturating_add(UPLOAD_IDLE_MS),
				readers: Vec::new(),
			},
		);
		self.usage.pending_bytes += size;
		self.usage.pending_files += 1;
		Ok(Upload { blob })
	}
	pub fn staged_count(&self, member: &FileMember) -> Result<usize, FileError> {
		self.check(&member.key)?;
		Ok(self
			.records
			.values()
			.filter(|r| r.member == member.key.id && r.phase == Phase::Staged && r.live())
			.count())
	}

	/// Transfer the exact membership's staged files in admission order. The
	/// calling application must validate its line mutation before this commit.
	pub fn post(&mut self, member: &FileMember) -> Result<Vec<HostedFile>, FileError> {
		let files = self.prepare_post(member)?;
		self.commit_post(&files);
		Ok(files)
	}
	pub(super) fn prepare_post(&mut self, member: &FileMember) -> Result<Vec<HostedFile>, FileError> {
		self.check(&member.key)?;
		self.collect();
		if !member.life.active.get() || !scope_live(&member.room_life) {
			return Err(FileError::Closed);
		}
		Ok(self
			.records
			.values()
			.filter(|r| r.member == member.key.id && r.phase == Phase::Staged)
			.map(|record| HostedFile {
				blob: record.blob.clone(),
				_owner: Rc::new(()),
			})
			.collect())
	}
	pub(super) fn commit_post(&mut self, files: &[HostedFile]) {
		for file in files {
			if let Some(record) = self.records.get_mut(&file.blob.key.id) {
				if record.phase != Phase::Staged {
					continue;
				}
				record.phase = Phase::Streaming;
				record.owner = Some(Rc::downgrade(&file._owner));
				if record.bytes.is_empty() {
					self.finish(file.blob.key.id);
				}
			}
		}
	}
	pub fn write(&mut self, upload: &Upload, chunk: &[u8]) -> Result<(), FileError> {
		self.check(&upload.blob.key)?;
		self.collect_file(upload.blob.key.id);
		let record = self.records.get_mut(&upload.blob.key.id).ok_or(FileError::Spent)?;
		match record.phase {
			Phase::Staged => return Err(FileError::NotPublished),
			Phase::Held => return Err(FileError::Spent),
			Phase::Streaming => {}
		}
		if chunk.len() > CHUNK_BYTES {
			return Err(FileError::ChunkTooLarge);
		}
		if chunk.len() > record.bytes.len() - record.written {
			return Err(FileError::PastEnd);
		}
		let end = record.written + chunk.len();
		record.bytes[record.written..end].copy_from_slice(chunk);
		record.written = end;
		record.deadline = self.now.saturating_add(UPLOAD_IDLE_MS);
		record.wake(false);
		if end == record.bytes.len() {
			self.finish(upload.blob.key.id);
		}
		Ok(())
	}
	/// Whether an upload is finished, discarded, or expired: nothing more can
	/// be written through it.
	pub fn upload_spent(&self, upload: &Upload) -> bool {
		self.records
			.get(&upload.blob.key.id)
			.is_none_or(|record| record.phase == Phase::Held || !record.live())
	}
	pub fn discard(&mut self, upload: &Upload) -> Result<(), FileError> {
		self.check(&upload.blob.key)?;
		self.collect_file(upload.blob.key.id);
		let record = self.records.get(&upload.blob.key.id).ok_or(FileError::Spent)?;
		if record.phase == Phase::Held {
			return Err(FileError::Spent);
		}
		self.expire(upload.blob.key.id);
		Ok(())
	}
	pub fn retire(&mut self, file: &HostedFile) -> Result<(), FileError> {
		self.check(&file.blob.key)?;
		self.expire(file.blob.key.id);
		Ok(())
	}
	pub fn close_member(&mut self, member: &FileMember) -> Result<(), FileError> {
		self.check(&member.key)?;
		member.life.active.set(false);
		self.collect();
		Ok(())
	}
	pub fn close_room(&mut self, room: &FileRoom) -> Result<(), FileError> {
		self.check(&room.key)?;
		room.life.active.set(false);
		self.collect();
		Ok(())
	}
	/// Monotonic host time is supplied by the platform. Advancing to a deadline
	/// expires that upload. Later writes cannot re-arm its retired generation.
	pub fn advance(&mut self, now_ms: u64) -> Result<(), FileError> {
		self.observe_time(now_ms)?;
		self.collect();
		Ok(())
	}
	/// Observe an event's host time without scanning unrelated files. Each
	/// operation checks the records it touches. Timer delivery reclaims all.
	pub(crate) fn observe_time(&mut self, now_ms: u64) -> Result<(), FileError> {
		if now_ms < self.now {
			return Err(FileError::ClockReversed);
		}
		self.now = now_ms;
		Ok(())
	}
	pub fn next_deadline(&self) -> Option<u64> {
		self.records
			.values()
			.filter(|r| r.phase != Phase::Held)
			.map(|r| r.deadline)
			.min()
	}
	/// Reclaim dropped scopes and line owners. Called before every mutation
	/// that could spend a budget. Reads already refuse their expired authority.
	pub fn collect(&mut self) {
		let expired: Vec<_> = self
			.records
			.iter()
			.filter(|(_, r)| !r.live() || (r.phase != Phase::Held && r.deadline <= self.now))
			.map(|(&id, _)| id)
			.collect();
		for id in expired {
			self.expire(id);
		}
	}
	pub(super) fn collect_file(&mut self, id: u64) {
		if self
			.records
			.get(&id)
			.is_some_and(|r| !r.live() || (r.phase != Phase::Held && r.deadline <= self.now))
		{
			self.expire(id);
		}
	}
	pub(super) fn expire(&mut self, id: u64) {
		if let Some(record) = self.records.remove(&id) {
			// Every removal consumes a distinct checked identity; this count
			// cannot exceed next_id and cannot wrap independently of it.
			self.retirements += 1;
			if record.phase == Phase::Held {
				self.usage.held_bytes -= record.bytes.len();
				self.usage.held_files -= 1;
				self.held.retain(|&held| held != id);
			} else {
				self.usage.pending_bytes -= record.bytes.len();
				self.usage.pending_files -= 1;
			}
		}
	}
	fn finish(&mut self, id: u64) {
		let record = &self.records[&id];
		let (size, room) = (record.bytes.len(), record.room);
		while self.usage.held_bytes > self.limits.held_bytes - size || self.usage.held_files >= self.limits.held_files {
			#[expect(
				clippy::expect_used,
				reason = "`admit` reserved held capacity for every pending file, so pressure past the limit means something older is held"
			)]
			self.expire(*self.held.front().expect("held global pressure"));
		}
		loop {
			let mut count = 0;
			let mut bytes = 0;
			let mut oldest = None;
			for &held in &self.held {
				let record = &self.records[&held];
				if record.room == room {
					oldest.get_or_insert(held);
					count += 1;
					bytes += record.bytes.len();
				}
			}
			if bytes <= self.limits.room_bytes - size && count < self.limits.room_files {
				break;
			}
			#[expect(
				clippy::expect_used,
				reason = "the loop found room pressure, so at least one held file in this room was counted into `oldest`"
			)]
			self.expire(oldest.expect("held room pressure"));
		}
		#[expect(
			clippy::expect_used,
			reason = "`finish` is called by `write` and `commit_post` with an id they just read from `records`"
		)]
		let record = self.records.get_mut(&id).expect("finishing upload");
		record.phase = Phase::Held;
		self.usage.pending_bytes -= size;
		self.usage.pending_files -= 1;
		self.usage.held_bytes += size;
		self.usage.held_files += 1;
		self.held.push_back(id);
	}
}
