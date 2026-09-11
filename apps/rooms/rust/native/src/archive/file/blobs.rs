//! Content-addressed disk custody. Journal commitment owns reference changes;
//! failed deletion remains explicit debt and never changes a committed reply.
use super::*;
use rooms_application::{
	archive::{blobs, Body},
	files::{CHUNK_BYTES, MAX_FILE_BYTES},
};
use sha2::{Digest, Sha256};
use std::{
	collections::BTreeMap,
	fs::{self, File},
	io::{Read, Seek, SeekFrom, Write},
};
use tokio::sync::mpsc;
pub(super) type Chunks = mpsc::Receiver<Result<super::Chunk, String>>;
pub(super) type Changes = BTreeMap<String, i32>;
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Usage {
	pub retained_bytes: usize,
	pub orphan_bytes: usize,
	pub pending_files: usize,
}
struct Item {
	references: usize,
	size: Option<usize>,
	verified: bool,
}
pub(super) struct Blobs {
	path: PathBuf,
	directory: File,
	items: BTreeMap<String, Item>,
	temporaries: BTreeMap<PathBuf, usize>,
	max_bytes: usize,
}
fn error(e: impl std::fmt::Display) -> String {
	e.to_string()
}
fn hash(bytes: impl AsRef<[u8]>) -> String {
	use std::fmt::Write;
	let mut hex = String::with_capacity(64);
	for b in bytes.as_ref() {
		write!(&mut hex, "{b:02x}").expect("String write");
	}
	hex
}
fn remove(path: &Path) -> std::io::Result<()> {
	match fs::symlink_metadata(path) {
		Ok(metadata) if metadata.is_dir() => fs::remove_dir_all(path),
		Ok(_) => fs::remove_file(path),
		Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
		Err(e) => Err(e),
	}
}
impl Blobs {
	pub(super) fn open(directory: &Directory, index: &Index, max_bytes: usize) -> Result<Self, String> {
		if max_bytes == 0 || max_bytes > blobs::MAX_BLOB_BYTES {
			return Err("invalid archive blob ceiling".into());
		}
		let path = directory.path.join("blobs");
		let mut builder = fs::DirBuilder::new();
		#[cfg(unix)]
		{
			use std::os::unix::fs::DirBuilderExt;
			builder.mode(0o700);
		}
		match builder.create(&path) {
			Ok(()) => directory.directory.sync_all().map_err(error)?,
			Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
			Err(e) => return Err(error(e)),
		}
		if !fs::symlink_metadata(&path).map_err(error)?.is_dir() {
			return Err("archive blobs must be a directory".into());
		}
		let mut result = Self {
			directory: File::open(&path).map_err(error)?,
			path,
			items: BTreeMap::new(),
			temporaries: BTreeMap::new(),
			max_bytes,
		};
		for entry in index.snapshot() {
			for (digest, delta) in Self::changes(None, Some(&entry.record)) {
				result.item(&digest).references += delta as usize;
			}
		}
		for entry in fs::read_dir(&result.path).map_err(error)? {
			let entry = entry.map_err(error)?;
			let name = entry.file_name().into_string().ok();
			let known = name.as_ref().is_some_and(|name| result.items.contains_key(name));
			if !known || !entry.file_type().map_err(error)?.is_file() {
				remove(&entry.path()).map_err(error)?;
				continue;
			}
			let size = entry.metadata().map_err(error)?.len();
			if size > MAX_FILE_BYTES as u64 {
				return Err("archive blob exceeds its file ceiling".into());
			}
			result.items.get_mut(name.as_ref().unwrap()).unwrap().size = Some(size as usize);
		}
		result.directory.sync_all().map_err(error)?;
		if result.usage().retained_bytes > max_bytes {
			return Err("archive blobs exceed their byte ceiling".into());
		}
		Ok(result)
	}
	fn item(&mut self, digest: &str) -> &mut Item {
		self.items.entry(digest.into()).or_insert(Item {
			references: 0,
			size: None,
			verified: false,
		})
	}
	pub(super) fn changes(retired: Option<&Record>, next: Option<&Record>) -> Changes {
		let mut changes = BTreeMap::new();
		for (record, delta) in [(retired, -1), (next, 1)] {
			if let Some(Body::Line { attachments, .. }) = record.map(Record::body) {
				for digest in attachments.iter().filter_map(|a| a.blob()) {
					*changes.entry(digest.into()).or_default() += delta;
				}
			}
		}
		changes
	}
	pub(super) fn permits(&self, changes: &Changes) -> bool {
		self.items
			.iter()
			.filter(|(digest, item)| item.references as i64 + i64::from(*changes.get(*digest).unwrap_or(&0)) > 0)
			.map(|(_, item)| item.size.unwrap_or(0))
			.sum::<usize>()
			<= self.max_bytes
	}
	pub(super) fn committed(&mut self, changes: Changes) {
		for (digest, delta) in changes {
			let item = self.item(&digest);
			item.references =
				usize::try_from(item.references as i64 + i64::from(delta)).expect("committed reference balance");
		}
		// The next explicit cleanup or startup retries any failed deletion. Its
		// physical bytes and entry remain charged until removal and directory sync.
		let _ = self.cleanup();
	}
	pub(super) fn usage(&self) -> Usage {
		let mut usage = Usage {
			orphan_bytes: self.temporaries.values().sum(),
			pending_files: self.temporaries.len(),
			..Default::default()
		};
		for item in self.items.values() {
			if item.references > 0 {
				usage.retained_bytes += item.size.unwrap_or(0);
			} else {
				usage.orphan_bytes += item.size.unwrap_or(0);
				usage.pending_files += 1;
			}
		}
		usage
	}
	pub(super) fn erase(&mut self) -> Result<(), String> {
		for item in self.items.values_mut() {
			item.references = 0;
		}
		self.cleanup()
	}
	pub(super) fn cleanup(&mut self) -> Result<(), String> {
		while let Some(path) = self.temporaries.first_key_value().map(|(path, _)| path.clone()) {
			remove(&path).map_err(error)?;
			self.directory.sync_all().map_err(error)?;
			self.temporaries.remove(&path);
		}
		let retired: Vec<_> = self
			.items
			.iter()
			.filter(|(_, item)| item.references == 0)
			.map(|(digest, _)| digest.clone())
			.collect();
		for digest in retired {
			remove(&self.path.join(&digest)).map_err(error)?;
			self.directory.sync_all().map_err(error)?;
			self.items.remove(&digest);
		}
		Ok(())
	}
	pub(super) fn begin(&mut self, size: usize) -> Result<Staged, String> {
		let usage = self.usage();
		if size > (self.max_bytes + blobs::MAX_STAGED_BYTES).saturating_sub(usage.retained_bytes + usage.orphan_bytes) {
			return Err("archive staged blobs exceed their byte ceiling".into());
		}
		let (temporary, file) = storage::atomic::staged(&self.path, "blob").map_err(error)?;
		self.temporaries.insert(temporary.clone(), size);
		Ok(Staged { temporary, file, size })
	}
	pub(super) fn finish(&mut self, staged: Written) -> Result<String, String> {
		let Written {
			temporary,
			size,
			digest,
		} = staged;
		// Charge the possible replacement before rename. If rename or directory
		// sync fails, cleanup may remove only unreferenced data, never prior bytes.
		let item = self.item(&digest);
		item.size = Some(size.max(item.size.unwrap_or(0)));
		item.verified = false;
		fs::rename(&temporary, self.path.join(&digest)).map_err(error)?;
		self.directory.sync_all().map_err(error)?;
		self.temporaries.remove(&temporary);
		let item = self.item(&digest);
		item.size = Some(size);
		item.verified = true;
		Ok(digest)
	}
	pub(super) fn read(
		&mut self,
		attachment: &rooms_application::archive::Attachment,
		offset: u64,
		length: usize,
	) -> Result<Vec<u8>, String> {
		let digest = attachment.blob().ok_or("archive attachment has no retained bytes")?;
		let path = self.path.join(digest);
		if !fs::symlink_metadata(&path).map_err(error)?.is_file() {
			return Err("archive blob must be a regular file".into());
		}
		let mut file = File::open(&path).map_err(error)?;
		if file.metadata().map_err(error)?.len() != attachment.size() as u64 {
			return Err("archive blob size disagrees with its metadata".into());
		}
		let item = self.items.get_mut(digest).ok_or("archive blob is not retained")?;
		if !item.verified {
			let mut hasher = Sha256::new();
			let mut buffer = vec![0; CHUNK_BYTES];
			let mut remaining = attachment.size();
			while remaining > 0 {
				let length = CHUNK_BYTES.min(remaining);
				file.read_exact(&mut buffer[..length]).map_err(error)?;
				hasher.update(&buffer[..length]);
				remaining -= length;
			}
			if file.read(&mut buffer[..1]).map_err(error)? != 0 {
				return Err("archive blob grew beyond its retained size".into());
			}
			if hash(hasher.finalize()) != digest {
				return Err("archive blob content does not match its digest".into());
			}
			item.verified = true;
		}
		file.seek(SeekFrom::Start(offset)).map_err(error)?;
		let mut bytes = vec![0; length];
		file.read_exact(&mut bytes).map_err(error)?;
		Ok(bytes)
	}
}

/// A single bounded file staging job. The blob index retains its temporary
/// path until commit or observed cleanup, including a failed source read.
pub(super) struct Staged {
	temporary: PathBuf,
	file: File,
	size: usize,
}
pub(super) struct Written {
	temporary: PathBuf,
	size: usize,
	digest: String,
}
impl Staged {
	pub(super) fn write(self, chunks: &mut Chunks) -> Result<Written, String> {
		let Self {
			temporary,
			mut file,
			size,
		} = self;
		let mut hasher = Sha256::new();
		let mut received = 0;
		while received < size {
			let expected = CHUNK_BYTES.min(size - received);
			let bytes = chunks
				.blocking_recv()
				.ok_or("archive file source observation ended")??;
			let bytes = bytes.as_ref();
			if bytes.len() != expected {
				return Err("archive source did not return exactly the requested bytes".into());
			}
			hasher.update(bytes);
			file.write_all(bytes).map_err(error)?;
			received += bytes.len();
		}
		file.sync_all().map_err(error)?;
		drop(file);
		let digest = hash(hasher.finalize());
		Ok(Written {
			temporary,
			size,
			digest,
		})
	}
}
