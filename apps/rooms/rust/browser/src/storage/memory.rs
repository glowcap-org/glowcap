//! Bounded page-lifetime fallback, selected only when storage cannot open.
//! Record authority and revision ordering use the same index as durable stores.
use super::{
	Error,
	blobs::{self, Staged},
};
use rooms_application::archive::{
	Facet, Filter, MAX_RECORDS, Record,
	blobs::{Address, MAX_BLOB_BYTES, Reader},
	index::{Index, Page},
};
use std::{cell::RefCell, collections::BTreeMap, rc::Rc};
use web_sys::Blob;

#[derive(Clone)]
pub(super) struct Memory(Rc<RefCell<State>>);
struct State {
	index: Index,
	files: BTreeMap<Address, Blob>,
	bytes: usize,
}
impl Memory {
	pub fn new() -> Result<Self, Error> {
		Ok(Self(Rc::new(RefCell::new(State {
			index: Index::new(MAX_RECORDS)?,
			files: BTreeMap::new(),
			bytes: 0,
		}))))
	}
	pub fn clear(&self) {
		let mut state = self.0.borrow_mut();
		state.index.clear();
		state.files.clear();
		state.bytes = 0;
	}
	pub fn put(&self, record: Record, staged: Vec<Staged>) -> Result<u64, Error> {
		let mut state = self.0.borrow_mut();
		let mut record = state.index.prepare_put(record);
		if !staged.is_empty() {
			record = record.with_blob_digests(staged.iter().map(|file| file.digest.clone()).collect())?;
		}
		let retired = state.index.retired_by(&record);
		let mut remove = Vec::new();
		let mut bytes = state.bytes;
		if let Some(retired) = retired {
			for (i, _) in rooms_application::archive::blobs::files(retired)
				.unwrap_or(&[])
				.iter()
				.enumerate()
			{
				let address = Address::of(retired, i)?;
				let retained = staged.is_empty()
					&& Address::of(&record, i).ok().as_ref() == Some(&address)
					&& rooms_application::archive::blobs::files(&record)
						.ok()
						.and_then(|f| f.get(i))
						.zip(
							rooms_application::archive::blobs::files(retired)
								.ok()
								.and_then(|f| f.get(i)),
						)
						.is_some_and(|(next, old)| next.blob().is_some() && next.blob() == old.blob());
				if !retained {
					if let Some(blob) = state.files.get(&address) {
						bytes -= blob.size() as usize;
					}
					remove.push(address);
				}
			}
		}
		let mut insert = Vec::with_capacity(staged.len());
		for (i, file) in staged.into_iter().enumerate() {
			bytes = bytes
				.checked_add(file.blob.size() as usize)
				.ok_or(Error::Invalid("archive byte count overflow"))?;
			insert.push((Address::of(&record, i)?, file.blob));
		}
		if bytes > MAX_BLOB_BYTES {
			return Err(Error::Invalid("archive blob budget is full"));
		}
		let revision = state
			.index
			.revision()
			.checked_add(1)
			.ok_or(Error::Invalid("archive revisions exhausted"))?;
		state.index.apply(revision, record)?;
		for address in remove {
			state.files.remove(&address);
		}
		state.files.extend(insert);
		state.bytes = bytes;
		Ok(revision)
	}
	pub fn read(&self, filter: &Filter, after: u64, limit: usize) -> Result<Page, Error> {
		Ok(self.0.borrow().index.read(filter, after, limit)?)
	}
	pub fn reader(&self, facet: Facet, digest: &str) -> Result<Reader, Error> {
		Ok(Reader::digest(&facet, &self.0.borrow().index, digest)?)
	}
	pub async fn bytes(&self, reader: Reader, offset: u64, maximum: usize) -> Result<Vec<u8>, Error> {
		let (blob, length) = {
			let state = self.0.borrow();
			let length = reader.read_length(&state.index, offset, maximum)?;
			let blob = state
				.files
				.get(reader.address())
				.ok_or(Error::Invalid("archive blob is unavailable"))?
				.clone();
			(blob, length)
		};
		let bytes = blobs::slice(&blob, offset, length).await?;
		// Erasure or replacement during the browser read invalidates held authority.
		reader.resolve(&self.0.borrow().index)?;
		Ok(bytes)
	}
}
