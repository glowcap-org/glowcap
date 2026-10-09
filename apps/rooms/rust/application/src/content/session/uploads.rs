//! Scalar upload intent and outcome. Exact source capabilities travel separately.
use super::{custody, workspace};
use crate::{
	fields::{List, Text},
	files::FileDescription,
};
use alloc::{string::String, vec, vec::Vec};
use serde::{Deserialize, Serialize};

#[derive(Debug)]
pub struct Refusal(&'static str);
impl core::fmt::Display for Refusal {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(self.0)
	}
}
impl core::error::Error for Refusal {}
type Result<T> = core::result::Result<T, Refusal>;
fn refuse(message: &'static str) -> Refusal {
	Refusal(message)
}

#[derive(Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Intent {
	pub upload: Kind,
	pub operation: String,
	pub base: u64,
	pub conversation: String,
	pub caption: String,
	pub previews: String,
	pub keep: List<u32, { crate::room::line::MAX_MESSAGE_FILES }>,
	#[serde(deserialize_with = "crate::fields::object_list")]
	pub files: List<Description, { crate::room::line::MAX_MESSAGE_FILES }>,
}
#[derive(Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
	Post,
	Refile(u64),
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Description {
	name: String,
	mime: String,
	size: usize,
	width: u32,
	height: u32,
}
impl Description {
	pub fn from_file(file: &FileDescription) -> Self {
		let (width, height) = file.dimensions();
		Self {
			name: file.name().into(),
			mime: file.mime().into(),
			size: file.size(),
			width,
			height,
		}
	}
	pub fn file(&self) -> Result<FileDescription> {
		FileDescription::parse(
			&self.name,
			&self.mime,
			self.size as u64,
			self.width.into(),
			self.height.into(),
		)
		.map_err(|_| refuse("invalid upload description"))
	}
}
impl Intent {
	fn validate(&self) -> Result<()> {
		if !crate::session::state::OperationId::accepts_utf16(self.operation.encode_utf16())
			|| crate::session::state::SafeInteger::<false>::new(self.base).is_none()
			|| !workspace::Id::accepts_utf16(self.conversation.encode_utf16())
			|| self.caption.len() > crate::room::line::MAX_LINE_BYTES
			|| self.keep.as_slice().len() + self.files.as_slice().len() > crate::room::line::MAX_MESSAGE_FILES
		{
			return Err(refuse("invalid upload intent bounds"));
		}
		match self.upload {
			Kind::Post if self.files.is_empty() || !self.keep.is_empty() => {
				return Err(refuse("invalid post file selection"));
			}
			Kind::Refile(line) if crate::room::message::LineId::new(line).is_none() => {
				return Err(refuse("invalid refile line"));
			}
			_ => {}
		}
		for (at, index) in self.keep.as_slice().iter().enumerate() {
			if self.keep.as_slice()[..at].contains(index) {
				return Err(refuse("duplicate kept file index"));
			}
		}
		for description in self.files.as_slice() {
			if Description::from_file(&description.file()?) != *description {
				return Err(refuse("invalid normalized file description"));
			}
		}
		let previews = crate::open_graph::Selection::decode(&self.caption, &self.previews)
			.map_err(|_| refuse("invalid upload previews"))?;
		if previews.encode() != self.previews {
			return Err(refuse("noncanonical upload previews"));
		}
		Ok(())
	}
	pub fn canonical(&self) -> Result<String> {
		self.validate()?;
		serde_json::to_string(self).map_err(|_| refuse("invalid upload intent"))
	}
	pub fn read(canonical: &str) -> Result<Self> {
		if canonical.len() > custody::MAX_AUTHORITY_BYTES {
			return Err(refuse("upload intent exceeds byte limit"));
		}
		let intent: Self =
			crate::fields::json_object(canonical).map_err(|_| refuse("invalid original upload intent"))?;
		if intent.files.as_slice().len() + intent.keep.as_slice().len() > crate::room::line::MAX_MESSAGE_FILES
			|| intent.canonical()? != canonical
		{
			return Err(refuse("invalid canonical upload intent"));
		}
		Ok(intent)
	}
	pub fn target_count(&self) -> usize {
		1 + usize::from(matches!(self.upload, Kind::Refile(_)))
	}
	pub fn coordinates(&self, intent: &workspace::Intent) -> Result<Vec<custody::Coordinate>> {
		let conversation = intent
			.conversations
			.as_slice()
			.iter()
			.find(|row| row.id().text().as_str() == Some(self.conversation.as_str()))
			.ok_or_else(|| refuse("file conversation is not selected"))?;
		let (role, key, lines) = match conversation {
			workspace::Conversation::Room(room) => (
				custody::Role::RoomFiles,
				room.files
					.map(|key| custody::FieldKey::new(key.slot(), key.generation())),
				room.lines.as_slice(),
			),
			workspace::Conversation::Direct(direct) if !direct.closed => (
				custody::Role::DirectAccess,
				direct
					.access
					.map(|key| custody::FieldKey::new(key.slot(), key.generation())),
				direct.lines.as_slice(),
			),
			_ => return Err(refuse("direct conversation is closed")),
		};
		let key = key.ok_or_else(|| refuse("original file delivery facet is absent"))?;
		let mut coordinates = vec![custody::Coordinate { role, key }];
		if let Kind::Refile(id) = self.upload {
			let key = lines
				.iter()
				.find(|row| row.id.get() == id)
				.ok_or_else(|| refuse("original line custody is absent"))?
				.handle;
			coordinates.push(custody::Coordinate {
				role: custody::Role::Line,
				key: custody::FieldKey::new(key.slot(), key.generation()),
			});
		}
		Ok(coordinates)
	}
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Outcome {
	pub line: Option<custody::FieldKey<custody::Line>>,
	pub id: Option<crate::fields::SafeInteger>,
	pub history: Option<super::results::History>,
	pub files_complete: bool,
	pub failure: Option<Text<4096>>,
}
