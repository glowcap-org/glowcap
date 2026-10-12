use super::super::{Steps, blobs::Staged, metadata, value};
use super::*;
use rooms_application::archive::{
	MAX_RECORDS,
	blobs::{self, Address, MAX_BLOB_BYTES},
};
use std::sync::Arc;
use wasm_bindgen::JsCast;
use web_sys::{IdbCursorWithValue, IdbTransactionMode};
pub(super) struct Put {
	record: Option<Record>,
	prior: Option<Arc<Record>>,
	files: Vec<Staged>,
	bytes: u64,
	pub revision: Option<u64>,
}
impl Put {
	fn empty() -> Self {
		Self {
			record: None,
			prior: None,
			files: Vec::new(),
			bytes: 0,
			revision: None,
		}
	}
}
pub(super) fn clear(database: &Database) -> Result<Operation<Put>, Error> {
	Operation::start(
		database,
		&[RECORDS, BLOBS, META],
		IdbTransactionMode::Readwrite,
		Put::empty(),
		metadata::clear,
	)
}
/// One committed transaction removes this source's rows and blob addresses
/// with exact shared byte accounting. The bounded cursor borrows each row only
/// for its delete. Unrelated source metadata and revision remain untouched.
pub(super) fn clear_source(database: &Database, source: DocumentText) -> Result<Operation<Put>, Error> {
	Operation::start(
		database,
		&[RECORDS, BLOBS, META],
		IdbTransactionMode::Readwrite,
		Put::empty(),
		move |steps| {
			let mut source = Some(source);
			steps.request(steps.store(META)?.get(&"blob-bytes".into())?, move |steps, row| {
				let source = source
					.take()
					.ok_or(Error::Invalid("duplicate archive erasure preparation"))?;
				let bytes = codec::meta(row, "blob-bytes", MAX_BLOB_BYTES as u64)?;
				steps.data(|put| {
					put.bytes = bytes;
					Ok(())
				})?;
				let mut seen = 0;
				steps.request(steps.store(RECORDS)?.open_cursor()?, move |steps, row| {
					if row.is_null() {
						return commit_bytes(steps);
					}
					seen += 1;
					if seen > MAX_RECORDS {
						return Err(Error::Invalid("archive storage exceeds its record ceiling"));
					}
					let cursor = row
						.dyn_into::<IdbCursorWithValue>()
						.map_err(|_| Error::Invalid("invalid archive cursor"))?;
					let entry = codec::decode(cursor.value()?)?;
					if entry.record.coordinates().source == source {
						steps.data(|put| {
							put.bytes = put
								.bytes
								.checked_sub(self::bytes(&entry.record))
								.ok_or(Error::Invalid("inconsistent archive byte count"))?;
							for (i, attachment) in blobs::files(&entry.record).unwrap_or(&[]).iter().enumerate() {
								if attachment.blob().is_some() {
									steps
										.store(BLOBS)?
										.delete(&codec::address_key(&Address::of(&entry.record, i)?))?;
								}
							}
							Ok(())
						})?;
						cursor.delete()?;
					}
					cursor.continue_()?;
					Ok(())
				})
			})
		},
	)
}
pub(super) fn put(
	database: &Database,
	record: Record,
	epoch: Option<DocumentText>,
	files: Vec<Staged>,
) -> Result<Operation<Put>, Error> {
	if epoch.as_ref().is_some_and(|epoch| !metadata::valid(epoch)) {
		return Err(Error::Invalid("invalid archive retention epoch"));
	}
	Operation::start(
		database,
		&[RECORDS, BLOBS, META],
		IdbTransactionMode::Readwrite,
		Put {
			record: Some(record),
			files,
			..Put::empty()
		},
		move |steps| {
			if let Some(epoch) = epoch {
				steps.request(steps.store(META)?.get(&"retention-epoch".into())?, move |steps, row| {
					if row.is_undefined() {
						steps
							.store(META)?
							.put(&metadata::row("retention-epoch", epoch.clone())?)?;
					} else if metadata::identity(row, "retention-epoch")? != epoch {
						return Ok(());
					}
					prepare(steps)
				})
			} else {
				prepare(steps)
			}
		},
	)
}
fn prepare(steps: &Steps<Put>) -> Result<(), Error> {
	let key = steps.data(|put| Ok(codec::key(put.record.as_ref().expect("put record"))))?;
	steps.request(steps.store(RECORDS)?.get(&key)?, move |steps, row| {
		steps.data(|put| {
			let prior = if row.is_undefined() {
				None
			} else {
				Some(codec::decode(row)?.record)
			};
			let record = put.record.take().expect("put record").prepare_put(prior.as_deref());
			let record = if put.files.is_empty() {
				record
			} else {
				record.with_blob_digests(put.files.iter().map(|f| f.digest.clone()).collect())?
			};
			put.record = Some(record);
			put.prior = prior;
			Ok(())
		})?;
		steps.request(steps.store(META)?.get(&"blob-bytes".into())?, account)
	})
}
fn bytes(record: &Record) -> u64 {
	blobs::files(record)
		.unwrap_or(&[])
		.iter()
		.filter(|a| a.blob().is_some())
		.map(|a| a.size() as u64)
		.sum()
}
fn account(steps: &Steps<Put>, row: wasm_bindgen::JsValue) -> Result<(), Error> {
	let retained = codec::meta(row, "blob-bytes", MAX_BLOB_BYTES as u64)?;
	steps.data(|put| {
		let record = put.record.as_ref().expect("put record");
		put.bytes = retained
			.checked_sub(put.prior.as_deref().map_or(0, bytes))
			.ok_or(Error::Invalid("inconsistent archive byte count"))?
			+ bytes(record);
		let store = steps.store(BLOBS)?;
		if let Some(prior) = &put.prior {
			let next = blobs::files(record).unwrap_or(&[]);
			for (i, a) in blobs::files(prior).unwrap_or(&[]).iter().enumerate() {
				if a.blob().is_some() && a.blob() != next.get(i).and_then(|a| a.blob()) {
					store.delete(&codec::address_key(&Address::of(prior, i)?))?;
				}
			}
		}
		for (i, staged) in put.files.iter().enumerate() {
			store.put(&value::object(&[
				("key", codec::address_key(&Address::of(record, i)?)),
				("digest", staged.digest.as_str().into()),
				("size", staged.blob.size().into()),
				("bytes", staged.blob.clone().into()),
			])?)?;
		}
		Ok(())
	})?;
	steps.request(steps.store(META)?.get(&"revision".into())?, move |steps, row| {
		let revision = codec::meta(row, "revision", MAX_SAFE - 1)? + 1;
		steps.store(META)?.put(&codec::number("revision", revision)?)?;
		steps.data(|put| {
			steps
				.store(RECORDS)?
				.put(&codec::encode(put.record.as_ref().expect("put record"), revision)?)?;
			put.revision = Some(revision);
			Ok(())
		})?;
		steps.request(steps.store(RECORDS)?.count()?, evict)
	})
}
fn evict(steps: &Steps<Put>, count: wasm_bindgen::JsValue) -> Result<(), Error> {
	let count = value::natural(&count, (MAX_RECORDS + 1) as u64)? as usize;
	if count <= MAX_RECORDS {
		return commit_bytes(steps);
	}
	// A valid database can exceed its ceiling by only this one inserted row.
	steps.request(steps.store(RECORDS)?.index("revision")?.open_cursor()?, |steps, row| {
		let cursor = row
			.dyn_into::<IdbCursorWithValue>()
			.map_err(|_| Error::Invalid("archive could not evict its oldest record"))?;
		let entry = codec::decode(cursor.value()?)?;
		steps.data(|put| {
			put.bytes = put
				.bytes
				.checked_sub(bytes(&entry.record))
				.ok_or(Error::Invalid("inconsistent archive byte count"))?;
			for (i, a) in blobs::files(&entry.record).unwrap_or(&[]).iter().enumerate() {
				if a.blob().is_some() {
					steps
						.store(BLOBS)?
						.delete(&codec::address_key(&Address::of(&entry.record, i)?))?;
				}
			}
			Ok(())
		})?;
		cursor.delete()?;
		commit_bytes(steps)
	})
}
fn commit_bytes(steps: &Steps<Put>) -> Result<(), Error> {
	steps.data(|put| {
		if put.bytes > MAX_BLOB_BYTES as u64 {
			return Err(Error::Invalid("archive blobs exceed their byte ceiling"));
		}
		steps.store(META)?.put(&codec::number("blob-bytes", put.bytes)?)?;
		Ok(())
	})
}
