//! Startup selects one archive for this page lifetime. A durable error never
//! redirects a write to memory. The recorder source is independent of the Host.
use super::{blobs, memory::Memory, Archive, Database, Error};
use crate::platform::Platform;
use rooms_application::{
	archive::{blobs::Reader, index::Page, Facet, Filter, Record},
	text::DocumentText,
};
use rooms_runtime::archive::{Backend, BlobAccess, Source};
use std::{cell::Cell, rc::Rc};

pub struct PageArchive {
	storage: Storage,
	platform: Platform,
	source: DocumentText,
	unavailable: Option<String>,
	erased: Rc<Cell<bool>>,
	serial: Rc<tokio::sync::Mutex<()>>,
}
enum Storage {
	Durable { archive: Archive, epoch: DocumentText },
	Volatile(Memory),
}
enum Reads {
	Durable(blobs::ReadAccess),
	Volatile(Memory),
}
impl PageArchive {
	pub async fn open(mut platform: Platform) -> Result<Self, Error> {
		let (storage, source, unavailable) = match Database::open().await {
			Ok(database) => {
				// Once the database opened, invalid metadata or failed writes
				// must be reported, preserving the existing durable account.
				let source = database.source(&mut platform).await?;
				let epoch = database.retention_epoch(&mut platform).await?;
				(
					Storage::Durable {
						archive: Archive::new(database),
						epoch,
					},
					source,
					None,
				)
			}
			Err(error @ (Error::Unavailable | Error::Blocked | Error::Platform(_))) => {
				let source = super::metadata::fresh(&mut platform)?;
				(Storage::Volatile(Memory::new()?), source, Some(error.to_string()))
			}
			Err(error) => return Err(error),
		};
		Ok(Self {
			storage,
			platform,
			source,
			unavailable,
			erased: Rc::default(),
			serial: Rc::default(),
		})
	}
	pub(crate) fn eraser(&self) -> super::Eraser {
		let (database, cache, memory) = match &self.storage {
			Storage::Durable { archive, .. } => (Some(archive.database.clone()), archive.cache.clone(), None),
			Storage::Volatile(memory) => (None, Default::default(), Some(memory.clone())),
		};
		super::Eraser {
			database,
			effects: super::erase::Effects {
				cache,
				memory,
				erased: self.erased.clone(),
			},
			pending: Default::default(),
			serial: self.serial.clone(),
		}
	}
	fn require_retained(&self) -> Result<(), Error> {
		if self.erased.get() {
			Err(Error::Closed)
		} else {
			Ok(())
		}
	}
	pub fn source(&self) -> &DocumentText {
		&self.source
	}
	/// Present this reason when persistence was unavailable at startup.
	pub fn unavailable(&self) -> Option<&str> {
		self.unavailable.as_deref()
	}
	pub async fn close(&mut self) -> Result<(), Error> {
		match &mut self.storage {
			Storage::Durable { archive, .. } => archive.close().await,
			Storage::Volatile(memory) => {
				memory.clear();
				Ok(())
			}
		}
	}
	async fn commit<S: Source>(&mut self, record: Record, sources: &[S]) -> Result<u64, Error> {
		let serial = self.serial.clone();
		let _serial = serial.lock().await;
		self.require_retained()?;
		match &mut self.storage {
			Storage::Durable { archive, epoch } => archive
				.put_retained_files(record, sources, epoch.clone())
				.await?
				.ok_or(Error::Invalid(
					"history recording was invalidated by erasure in another tab",
				)),
			Storage::Volatile(memory) => {
				let staged = if sources.is_empty() {
					Vec::new()
				} else {
					blobs::stage(&record, sources).await?
				};
				if self.erased.get() {
					return Err(Error::Closed);
				}
				memory.put(record, staged)
			}
		}
	}
}
pub struct ReadAccess(Reads);
impl BlobAccess for ReadAccess {
	async fn read(&self, reader: Reader, offset: u64, maximum: usize) -> Result<Vec<u8>, String> {
		match &self.0 {
			Reads::Durable(access) => access.read(reader, offset, maximum).await,
			Reads::Volatile(memory) => memory.bytes(reader, offset, maximum).await.map_err(|e| e.to_string()),
		}
	}
}
impl Backend for PageArchive {
	fn blob_access(&self) -> impl BlobAccess + use<> {
		ReadAccess(match &self.storage {
			Storage::Durable { archive, .. } => Reads::Durable(archive.blob_access()),
			Storage::Volatile(memory) => Reads::Volatile(memory.clone()),
		})
	}
	fn retains_blobs(&self) -> bool {
		true
	}
	async fn put(&mut self, record: Record) -> Result<u64, String> {
		let serial = self.serial.clone();
		let _serial = serial.lock().await;
		self.require_retained().map_err(|e| e.to_string())?;
		// Metadata updates preserve only digests already owned by this backend.
		match &mut self.storage {
			Storage::Durable { archive, epoch } => archive
				.put_retained(record, epoch.clone())
				.await
				.map_err(|e| e.to_string())?
				.ok_or_else(|| "history recording was invalidated by erasure in another tab".into()),
			Storage::Volatile(memory) => memory.put(record, Vec::new()).map_err(|e| e.to_string()),
		}
	}
	async fn put_files<S: Source>(&mut self, record: Record, sources: &[S]) -> Result<u64, String> {
		self.commit(record, sources).await.map_err(|e| e.to_string())
	}
	async fn read(&mut self, filter: &Filter, after: u64, limit: usize) -> Result<Page, String> {
		match &mut self.storage {
			Storage::Durable { archive, .. } => archive.read(filter, after, limit).await,
			Storage::Volatile(memory) => memory.read(filter, after, limit),
		}
		.map_err(|e| e.to_string())
	}
	async fn clear(&mut self) -> Result<(), String> {
		let serial = self.serial.clone();
		let _serial = serial.lock().await;
		self.require_retained().map_err(|e| e.to_string())?;
		match &mut self.storage {
			Storage::Durable { archive, epoch } => {
				archive.settle().await.map_err(|e| e.to_string())?;
				let next = super::metadata::fresh(&mut self.platform).map_err(|e| e.to_string())?;
				archive
					.database
					.set_retention_epoch(next.clone(), true)
					.await
					.map_err(|e| e.to_string())?;
				*epoch = next;
				archive.cache.clear();
			}
			Storage::Volatile(memory) => memory.clear(),
		}
		Ok(())
	}
	async fn blob_reader(&mut self, facet: Facet, digest: String) -> Result<Reader, String> {
		match &mut self.storage {
			Storage::Durable { archive, .. } => archive.blob_reader(facet, digest).await,
			Storage::Volatile(memory) => memory.reader(facet, &digest),
		}
		.map_err(|e| e.to_string())
	}
	async fn read_blob(&mut self, reader: Reader, offset: u64, maximum: usize) -> Result<Vec<u8>, String> {
		self.blob_access().read(reader, offset, maximum).await
	}
}
