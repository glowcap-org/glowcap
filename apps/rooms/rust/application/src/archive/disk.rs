//! Version-one JSONL snapshots and committed tails. Recovery produces a fresh
//! index. The caller decides when a torn-tail repair becomes durable.
use super::{
	Error, MAX_RECORDS, Record,
	index::{Entry, Index},
};
use crate::fields::SafeInteger;
use alloc::{string::String, sync::Arc, vec::Vec};
use serde::{Deserialize, Serialize};
pub const FILE: &str = "archive.jsonl";
pub const FORMAT: &str = "glowcap-rooms-member-archive";
pub const MAX_FILE_BYTES: usize = 128 * 1024 * 1024;
pub const COMPACT_DELTA: usize = 512;
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Header {
	archive: String,
	version: SafeInteger,
	revision: SafeInteger,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Row {
	revision: SafeInteger<true>,
	record: Record,
}
#[derive(Serialize)]
struct BorrowedRow<'a> {
	revision: u64,
	record: &'a Record,
}
pub struct Recovered {
	pub index: Index,
	pub repair_tail: bool,
	pub rows: usize,
}
/// Recovery reports the written schema without acquiring filesystem authority.
#[derive(Debug)]
pub enum RecoveryError {
	Header,
	Unsupported { format: String, version: u64 },
	Data(Error),
}
impl From<Error> for RecoveryError {
	fn from(error: Error) -> Self {
		Self::Data(error)
	}
}
impl core::fmt::Display for RecoveryError {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		match self {
			Self::Header => f.write_str("invalid archive header"),
			Self::Unsupported { format, version } => write!(
				f,
				"archive written as {format} version {version}; this build reads {FORMAT} version 1; use a compatible build to recover the archive, or remove its state directory to start empty"
			),
			Self::Data(error) => error.fmt(f),
		}
	}
}
impl core::error::Error for RecoveryError {}
fn json(_error: serde_json::Error) -> Error {
	Error::Document
}
pub fn recover(
	bytes: &[u8],
	capacity: usize,
	compact_delta: usize,
	max_bytes: usize,
) -> Result<Recovered, RecoveryError> {
	if compact_delta == 0 || max_bytes == 0 || bytes.len() > max_bytes {
		return Err(Error::Capacity.into());
	}
	let max_rows = MAX_RECORDS.checked_add(compact_delta).ok_or(Error::Capacity)?;
	let end = bytes.iter().rposition(|b| *b == b'\n').ok_or(Error::Document)? + 1;
	let text = core::str::from_utf8(&bytes[..end]).map_err(|_| Error::Document)?;
	let mut lines = text.split_terminator('\n');
	let header: Header =
		serde_json::from_str(lines.next().ok_or(RecoveryError::Header)?).map_err(|_| RecoveryError::Header)?;
	if header.archive != FORMAT || header.version.get() != 1 {
		return Err(RecoveryError::Unsupported {
			format: header.archive,
			version: header.version.get(),
		});
	}
	let mut index = Index::new(capacity)?;
	let mut snapshot = Some(Vec::new());
	let mut rows = 0;
	for line in lines {
		if rows == max_rows {
			return Err(Error::Capacity.into());
		}
		rows += 1;
		let row: Row = serde_json::from_str(line).map_err(json)?;
		let revision = row.revision.get();
		if let Some(snapshot) = snapshot.as_mut().filter(|_| revision <= header.revision.get()) {
			if snapshot.len() == capacity {
				return Err(Error::Capacity.into());
			}
			snapshot.push(Entry {
				revision,
				record: Arc::new(row.record),
			});
		} else {
			if let Some(snapshot) = snapshot.take() {
				index.restore(header.revision.get(), snapshot)?;
			}
			index.apply(revision, row.record)?;
		}
	}
	if let Some(snapshot) = snapshot {
		index.restore(header.revision.get(), snapshot)?;
	}
	Ok(Recovered {
		index,
		repair_tail: end != bytes.len(),
		rows,
	})
}
/// Each JSONL row is encoded once into its owned write buffer. Native I/O can
/// stream these buffers without flattening or retaining a second whole snapshot.
pub struct Snapshot {
	chunks: Vec<Vec<u8>>,
	bytes: usize,
}
impl Snapshot {
	pub fn byte_len(&self) -> usize {
		self.bytes
	}
	pub fn chunks(&self) -> impl ExactSizeIterator<Item = &[u8]> {
		self.chunks.iter().map(Vec::as_slice)
	}
	pub fn into_chunks(self) -> Vec<Vec<u8>> {
		self.chunks
	}
}
fn row(value: &impl Serialize, max: usize) -> Result<Vec<u8>, Error> {
	let mut bytes = serde_json::to_vec(value).map_err(json)?;
	bytes.push(b'\n');
	if bytes.len() > max {
		return Err(Error::Capacity);
	}
	Ok(bytes)
}
pub fn snapshot(index: &Index, max_bytes: usize) -> Result<Snapshot, Error> {
	let header = row(
		&Header {
			archive: FORMAT.into(),
			version: SafeInteger::literal(1),
			revision: SafeInteger::new(index.revision()).ok_or(Error::Revision)?,
		},
		max_bytes,
	)?;
	let mut result = Snapshot {
		bytes: header.len(),
		chunks: Vec::with_capacity(index.len() + 1),
	};
	result.chunks.push(header);
	for entry in index.snapshot() {
		let bytes = revision(entry.revision, &entry.record, max_bytes - result.bytes)?;
		result.bytes += bytes.len();
		result.chunks.push(bytes);
	}
	Ok(result)
}
pub fn revision(revision: u64, record: &Record, max_bytes: usize) -> Result<Vec<u8>, Error> {
	if SafeInteger::<true>::new(revision).is_none() {
		return Err(Error::Revision);
	}
	row(&BorrowedRow { revision, record }, max_bytes)
}
