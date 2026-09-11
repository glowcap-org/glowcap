//! Retained archive metadata can contain lossless document text. Live file
//! capabilities keep their existing UTF-8 description; both share admission.
use super::{records::digest, Error};
use crate::{files, text::DocumentText};
use alloc::string::String;
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Attachment {
	name: DocumentText,
	mime: DocumentText,
	size: usize,
	width: u32,
	height: u32,
	blob: Option<String>,
}
impl Attachment {
	pub fn new(
		name: DocumentText,
		mime: DocumentText,
		size: u64,
		width: u64,
		height: u64,
		blob: Option<String>,
	) -> Result<Self, Error> {
		files::validate_description(name.utf16().take(161).count(), mime.utf16().take(81).count(), size)
			.map_err(|_| Error::Record)?;
		if width > 65535 || height > 65535 || blob.as_deref().is_some_and(|s| !digest(s)) {
			return Err(Error::Record);
		}
		Ok(Self {
			name,
			mime,
			size: size as usize,
			width: width as u32,
			height: height as u32,
			blob,
		})
	}
	pub(super) fn preserve_blob(&mut self, prior: Option<&Self>) {
		self.blob = prior
			.filter(|prior| self.metadata_matches(prior))
			.and_then(|prior| prior.blob.clone());
	}
	pub fn metadata_matches(&self, other: &Self) -> bool {
		self.name == other.name
			&& self.mime == other.mime
			&& self.size == other.size
			&& self.dimensions() == other.dimensions()
	}
	pub fn matches_description(&self, other: &files::FileDescription) -> bool {
		self.name.as_str() == Some(other.name())
			&& self.mime.as_str() == Some(other.mime())
			&& self.size == other.size()
			&& self.dimensions() == other.dimensions()
	}
	/// Live capabilities require UTF-8 metadata. Lossless document text stays
	/// intact when it cannot be represented by that existing wire contract.
	pub fn live_description(&self) -> Result<files::FileDescription, Error> {
		files::FileDescription::parse(
			self.name.as_str().ok_or(Error::Blob)?,
			self.mime.as_str().ok_or(Error::Blob)?,
			self.size as u64,
			self.width as u64,
			self.height as u64,
		)
		.map_err(|_| Error::Blob)
	}
	pub(super) fn set_blob(&mut self, blob: String) {
		self.blob = Some(blob);
	}
	pub fn name(&self) -> &DocumentText {
		&self.name
	}
	pub fn mime(&self) -> &DocumentText {
		&self.mime
	}
	pub fn size(&self) -> usize {
		self.size
	}
	pub fn dimensions(&self) -> (u32, u32) {
		(self.width, self.height)
	}
	pub fn blob(&self) -> Option<&str> {
		self.blob.as_deref()
	}
	pub fn heap_bytes(&self) -> usize {
		self.name.heap_bytes() + self.mime.heap_bytes() + self.blob.as_ref().map_or(0, String::capacity)
	}
}
