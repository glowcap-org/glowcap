//! Blob construction hashes bounded source chunks once. Reads recheck committed
//! record authority in one transaction, then verify immutable bytes outside it.
use super::{
	Archive, Database, Error, Operation,
	records::{self, BLOBS, RECORDS, codec},
	value,
};
use js_sys::{Array, Uint8Array, futures::JsFuture};
use rooms_application::{
	archive::{
		Facet, Filter, Record,
		blobs::{self, MAX_STAGED_BYTES, Reader},
		index::Page,
	},
	files::CHUNK_BYTES,
	text::DocumentText,
};
use rooms_runtime::archive::{Backend, BlobAccess, Source};
use sha2::{Digest, Sha256};
use std::{cell::RefCell, collections::VecDeque, rc::Rc};
use wasm_bindgen::JsCast;
use web_sys::{Blob, IdbTransactionMode};
pub(super) struct Staged {
	pub digest: String,
	pub blob: Blob,
}
struct Verified {
	digest: String,
	blob: Blob,
}
/// Verified blobs held for reuse, within `MAX_STAGED_BYTES` in all.
const CACHED_BLOBS: usize = 32;
#[derive(Clone, Default)]
pub(super) struct Cache(Rc<RefCell<VecDeque<Verified>>>);
impl Cache {
	pub fn clear(&self) {
		self.0.borrow_mut().clear();
	}
	fn get(&self, digest: &str, size: usize) -> Option<Blob> {
		let mut cache = self.0.borrow_mut();
		let at = cache
			.iter()
			.position(|held| held.digest == digest && held.blob.size() == size as f64)?;
		let held = cache.remove(at)?;
		let result = held.blob.clone();
		cache.push_back(held);
		Some(result)
	}
	fn retain(&self, digest: String, blob: Blob) {
		let mut cache = self.0.borrow_mut();
		cache.retain(|held| held.digest != digest);
		while cache.len() >= CACHED_BLOBS
			|| cache.iter().map(|v| v.blob.size() as usize).sum::<usize>() + blob.size() as usize > MAX_STAGED_BYTES
		{
			if cache.pop_front().is_none() {
				return;
			}
		}
		cache.push_back(Verified { digest, blob });
	}
}
pub(super) async fn stage<S: Source>(record: &Record, sources: &[S]) -> Result<Vec<Staged>, Error> {
	blobs::validate_sources(record, sources.iter().map(Source::description))?;
	let mut staged = Vec::with_capacity(sources.len());
	for source in sources {
		let mut hash = Sha256::new();
		let chunks = Array::new();
		let size = source.description().size();
		let mut offset = 0;
		while offset < size {
			let length = CHUNK_BYTES.min(size - offset);
			// The source is the caller's, so its refusal is reported as given
			// rather than recorded as this page's storage failing.
			let chunk = source
				.read(offset as u64, length)
				.await
				.map_err(|error| Error::Platform(error.into_refusal()))?;
			if chunk.as_ref().len() != length {
				return Err(Error::Invalid(
					"archive source did not return exactly the requested bytes",
				));
			}
			hash.update(chunk.as_ref());
			// Blob snapshots JS buffers. This transfer copy is one bounded chunk;
			// no second complete file is assembled in Wasm to compute its digest.
			chunks.push(&Uint8Array::from(chunk.as_ref()));
			offset += length;
		}
		staged.push(Staged {
			digest: rooms_application::fields::lower_hex(&hash.finalize()),
			blob: Blob::new_with_u8_array_sequence(&chunks)?,
		});
	}
	Ok(staged)
}
#[derive(Clone)]
pub struct ReadAccess {
	database: Database,
	cache: Cache,
}
impl ReadAccess {
	async fn bytes(&self, reader: Reader, offset: u64, maximum: usize) -> Result<Vec<u8>, Error> {
		let mut operation = Operation::start(
			&self.database,
			&[RECORDS, BLOBS],
			IdbTransactionMode::Readonly,
			None,
			move |steps| {
				steps.request(
					steps
						.store(RECORDS)?
						.index("coordinates")?
						.get(&codec::address_coordinates(reader.address())?)?,
					move |steps, row| {
						let entry = codec::decode(row)?;
						let attachment = reader.resolve_record(&entry.record)?;
						let length = reader.record_read_length(&entry.record, offset, maximum)?;
						let size = attachment.size();
						let digest = attachment
							.blob()
							.ok_or(Error::Invalid("resolved attachment has no blob"))?
							.to_owned();
						let key = codec::address_key(reader.address())?;
						steps.request(steps.store(BLOBS)?.get(&key)?, move |steps, row| {
							value::shape(&row, &["key", "digest", "size", "bytes"])?;
							if value::get(&row, "key")? != key
								|| value::get(&row, "digest")? != wasm_bindgen::JsValue::from_str(&digest)
								|| value::natural(&value::get(&row, "size")?, MAX_STAGED_BYTES as u64)? != size as u64
							{
								return Err(Error::Invalid("archive blob does not match its record"));
							}
							let blob = value::get(&row, "bytes")?
								.dyn_into::<Blob>()
								.map_err(|_| Error::Invalid("archive blob has no bytes"))?;
							if blob.size() != size as f64 {
								return Err(Error::Invalid("archive blob has the wrong size"));
							}
							steps.data(|result| {
								*result = Some((blob, digest.clone(), size, length));
								Ok(())
							})
						})
					},
				)
			},
		)?;
		let (blob, digest, size, length) = operation
			.wait()
			.await?
			.ok_or(Error::Invalid("archive blob is unavailable"))?;
		let blob = if let Some(verified) = self.cache.get(&digest, size) {
			verified
		} else {
			let mut hash = Sha256::new();
			let mut at = 0;
			while at < size {
				let chunk = slice(&blob, at as u64, CHUNK_BYTES.min(size - at)).await?;
				hash.update(&chunk);
				at += chunk.len();
			}
			if rooms_application::fields::lower_hex(&hash.finalize()) != digest {
				return Err(Error::Invalid("archive blob digest does not match its bytes"));
			}
			self.cache.retain(digest, blob.clone());
			blob
		};
		slice(&blob, offset, length).await
	}
}
pub(super) async fn slice(blob: &Blob, offset: u64, length: usize) -> Result<Vec<u8>, Error> {
	if length == 0 {
		return Ok(Vec::new());
	}
	let part = blob.slice_with_f64_and_f64(offset as f64, (offset + length as u64) as f64)?;
	let value = JsFuture::from(part.array_buffer()).await?;
	let bytes = Uint8Array::new(&value);
	if bytes.length() as usize != length {
		return Err(Error::Invalid("archive blob returned an incomplete chunk"));
	}
	Ok(bytes.to_vec())
}
impl Archive {
	pub fn blob_access(&self) -> ReadAccess {
		ReadAccess {
			database: self.database.clone(),
			cache: self.cache.clone(),
		}
	}
	pub async fn put_files<S: Source>(&mut self, record: Record, sources: &[S]) -> Result<u64, Error> {
		self.settle().await?;
		let files = stage(&record, sources).await?;
		self.commit(record, None, files)
			.await?
			.ok_or(Error::Invalid("unrestricted archive file write was not admitted"))
	}
	pub async fn put_retained_files<S: Source>(
		&mut self,
		record: Record,
		sources: &[S],
		epoch: DocumentText,
	) -> Result<Option<u64>, Error> {
		self.settle().await?;
		if !super::metadata::valid(&epoch) {
			return Err(Error::Invalid("invalid archive retention epoch"));
		}
		let files = stage(&record, sources).await?;
		self.commit(record, Some(epoch), files).await
	}
	pub async fn blob_reader(&mut self, facet: Facet, digest: String) -> Result<Reader, Error> {
		self.settle().await?;
		records::reader(&self.database, facet, digest)?
			.wait()
			.await?
			.ok_or(Error::Invalid("archive blob is unavailable"))
	}
}
impl BlobAccess for ReadAccess {
	async fn read(&self, reader: Reader, offset: u64, maximum: usize) -> Result<Vec<u8>, rooms_runtime::Error> {
		Ok(self.bytes(reader, offset, maximum).await?)
	}
}
impl Backend for Archive {
	fn blob_access(&self) -> impl BlobAccess + use<> {
		self.blob_access()
	}
	fn retains_blobs(&self) -> bool {
		true
	}
	async fn put(&mut self, record: Record) -> Result<u64, rooms_runtime::Error> {
		Ok(self.put(record).await?)
	}
	async fn read(&mut self, filter: &Filter, after: u64, limit: usize) -> Result<Page, rooms_runtime::Error> {
		Ok(self.read(filter, after, limit).await?)
	}
	async fn clear(&mut self) -> Result<(), rooms_runtime::Error> {
		Ok(self.clear().await?)
	}
	async fn put_files<S: Source>(&mut self, record: Record, sources: &[S]) -> Result<u64, rooms_runtime::Error> {
		Ok(self.put_files(record, sources).await?)
	}
	async fn blob_reader(&mut self, facet: Facet, digest: String) -> Result<Reader, rooms_runtime::Error> {
		Ok(self.blob_reader(facet, digest).await?)
	}
	async fn read_blob(
		&mut self,
		reader: Reader,
		offset: u64,
		maximum: usize,
	) -> Result<Vec<u8>, rooms_runtime::Error> {
		self.settle().await?;
		self.blob_access().read(reader, offset, maximum).await
	}
}
