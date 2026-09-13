//! An archive reader names one attachment position and expected content. Every
//! read rechecks the current record and scope; metadata alone never selects bytes.
use super::{Attachment, Body, ConversationKind, Coordinates, Error, Facet, Filter, Record, index::Index, records};
use crate::{
	fields::SafeInteger,
	files::{CHUNK_BYTES, FileDescription, transfer},
	text::DocumentText,
};
use alloc::{string::String, sync::Arc};
pub mod admission;
pub const MAX_BLOB_BYTES: usize = 512 * 1024 * 1024;
pub const MAX_STAGED_BYTES: usize = 64 * 1024 * 1024;
pub const MAX_READERS_PER_SESSION: usize = 512;
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Address {
	pub(super) coordinates: Coordinates,
	pub(super) kind: ConversationKind,
	pub(super) directory: DocumentText,
	pub(super) conversation: DocumentText,
	index: usize,
}
impl Address {
	pub fn of(record: &Record, index: usize) -> Result<Self, Error> {
		let Body::Line {
			conversation_kind,
			conversation,
			attachments,
			..
		} = record.body()
		else {
			return Err(Error::Blob);
		};
		if index >= attachments.len() {
			return Err(Error::Blob);
		}
		Ok(Self {
			coordinates: record.coordinates().clone(),
			kind: *conversation_kind,
			directory: record.directory().clone(),
			conversation: conversation.clone(),
			index,
		})
	}
	pub fn coordinates(&self) -> &Coordinates {
		&self.coordinates
	}
	pub fn conversation_kind(&self) -> ConversationKind {
		self.kind
	}
	pub fn directory(&self) -> &DocumentText {
		&self.directory
	}
	pub fn conversation(&self) -> &DocumentText {
		&self.conversation
	}
	pub fn index(&self) -> usize {
		self.index
	}
}
#[derive(Clone)]
pub struct Reader(Arc<ReaderState>);
#[derive(Clone)]
struct ReaderState {
	address: Address,
	scope: Filter,
	digest: String,
}
impl Reader {
	pub fn attachment(facet: &Facet, record: &Record, index: usize) -> Result<Self, Error> {
		if !facet.scope().matches(record) {
			return Err(Error::Filter);
		}
		let attachment = files(record)?.get(index).ok_or(Error::Blob)?;
		Ok(Self(Arc::new(ReaderState {
			address: Address::of(record, index)?,
			scope: facet.scope().clone(),
			digest: attachment.blob().ok_or(Error::Blob)?.into(),
		})))
	}
	pub fn digest(facet: &Facet, index: &Index, digest: &str) -> Result<Self, Error> {
		if !records::digest(digest) {
			return Err(Error::Blob);
		}
		let filter = Filter {
			digest: Some(digest.into()),
			..Default::default()
		};
		let scope = facet.scope().intersect(&filter).ok_or(Error::Filter)?;
		let record = index.matching_line(&scope).ok_or(Error::Blob)?;
		Self::matching(facet, record, digest)
	}
	/// Indexed storage can supply one candidate without rebuilding an in-memory
	/// index. The shared authority still checks its scope and attachment digest.
	pub fn matching(facet: &Facet, record: &Record, digest: &str) -> Result<Self, Error> {
		if !records::digest(digest) {
			return Err(Error::Blob);
		}
		let at = files(record)?
			.iter()
			.position(|a| a.blob() == Some(digest))
			.ok_or(Error::Blob)?;
		Self::attachment(facet, record, at)
	}
	/// A backend may select the address, but the requested digest and scope
	/// still bound the authority the hosted adapter returns.
	pub fn restrict(self, scope: &Filter, digest: &str) -> Result<Self, Error> {
		if self.0.digest != digest {
			return Err(Error::Blob);
		}
		let narrowed = self.0.scope.intersect(scope).ok_or(Error::Filter)?;
		if narrowed == self.0.scope {
			return Ok(self);
		}
		let mut state = (*self.0).clone();
		state.scope = narrowed;
		Ok(Self(Arc::new(state)))
	}
	pub fn resolve<'a>(&self, index: &'a Index) -> Result<&'a Attachment, Error> {
		let record = index.line(&self.0.address).ok_or(Error::Blob)?;
		self.resolve_record(record)
	}
	pub fn address(&self) -> &Address {
		&self.0.address
	}
	pub fn resolve_record<'a>(&self, record: &'a Record) -> Result<&'a Attachment, Error> {
		use super::index::Identity;
		if self.0.address.parts() != record.parts() {
			return Err(Error::Blob);
		}
		if !self.0.scope.matches(record) {
			return Err(Error::Filter);
		}
		files(record)?
			.get(self.0.address.index)
			.filter(|a| a.blob() == Some(self.0.digest.as_str()))
			.ok_or(Error::Blob)
	}
	pub fn read_length(&self, index: &Index, offset: u64, maximum: usize) -> Result<usize, Error> {
		Self::bounded_length(self.resolve(index)?, offset, maximum)
	}
	pub fn record_read_length(&self, record: &Record, offset: u64, maximum: usize) -> Result<usize, Error> {
		Self::bounded_length(self.resolve_record(record)?, offset, maximum)
	}
	fn bounded_length(attachment: &Attachment, offset: u64, maximum: usize) -> Result<usize, Error> {
		if SafeInteger::<false>::new(offset).is_none() || maximum == 0 || maximum > CHUNK_BYTES {
			return Err(Error::Blob);
		}
		transfer::read_length(attachment.size(), offset, maximum).map_err(|_| Error::Blob)
	}
	pub fn retained_bytes(&self) -> usize {
		core::mem::size_of::<Self>()
			+ core::mem::size_of::<ReaderState>()
			+ 2 * core::mem::size_of::<usize>()
			+ self.0.scope.retained_bytes()
			+ self.0.digest.capacity()
			+ self.0.address.coordinates.source.heap_bytes()
			+ self.0.address.coordinates.generation.heap_bytes()
			+ self.0.address.coordinates.id.heap_bytes()
			+ self.0.address.directory.heap_bytes()
			+ self.0.address.conversation.heap_bytes()
	}
}
pub fn files(record: &Record) -> Result<&[Attachment], Error> {
	match record.body() {
		Body::Line { attachments, .. } => Ok(attachments),
		_ => Err(Error::Blob),
	}
}
pub fn validate_sources<'a>(
	record: &Record,
	sources: impl ExactSizeIterator<Item = &'a FileDescription>,
) -> Result<(), Error> {
	let files = files(record)?;
	if files.len() != sources.len() || !files.iter().zip(sources).all(|(a, b)| a.matches_description(b)) {
		return Err(Error::Blob);
	}
	Ok(())
}
