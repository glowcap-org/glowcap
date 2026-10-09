//! Private provenance follows the exact retained line, independently of receipts.
//! Exported workspace intent cannot supply or replace these recording origins.
use super::{custody, uploads, workspace};
use crate::{
	fields::{List, Text},
	open_graph::Selection,
};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct File {
	pub description: uploads::Description,
	pub source: custody::FieldKey<custody::SourceBlob>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Origin {
	pub line: custody::FieldKey<custody::Line>,
	pub source: custody::FieldKey<custody::SessionAccess>,
	pub route: custody::FieldKey<custody::DirectAccess>,
	pub id: crate::session::state::SafeInteger,
	pub generation: Text<128, true>,
	pub directory: workspace::Id,
	pub conversation: workspace::Id,
	pub from: Text<32, true>,
	pub previews: Selection,
	pub files: List<File, { crate::room::line::MAX_MESSAGE_FILES }>,
}

pub fn release_sources<R: custody::References, C>(record: &mut workspace::Record<R, C>, keys: &[custody::Coordinate]) {
	for key in keys {
		if record.intent.coordinates().any(|held| held == *key)
			|| record.outgoing.as_slice().iter().any(|origin| {
				(key.role == custody::Role::SessionAccess
					&& key.key.slot() == origin.source.slot()
					&& key.key.generation() == origin.source.generation())
					|| (key.role == custody::Role::SourceBlob
						&& origin.files.as_slice().iter().any(|file| {
							key.key.slot() == file.source.slot() && key.key.generation() == file.source.generation()
						}))
			}) || record.bridges.as_slice().iter().any(|witness| {
			(key.role == custody::Role::SessionAccess
				&& key.key.slot() == witness.source.slot()
				&& key.key.generation() == witness.source.generation())
				|| witness.access == Some(*key)
		}) {
			continue;
		}
		record.custody.remove(*key);
	}
}

/// Forgetting a line releases its private provenance in the same transaction.
/// Receipts retain their own source occurrences independently of this custody.
pub fn retire<R: custody::References, C>(record: &mut workspace::Record<R, C>) {
	let (kept, retired): (alloc::vec::Vec<_>, alloc::vec::Vec<_>) = core::mem::take(&mut record.outgoing)
		.0
		.into_iter()
		.partition(|origin| record.custody.line(origin.line).is_some());
	record.outgoing = List::new(kept).expect("existing bounded origins");
	for origin in retired {
		let coordinate = |role, slot, generation| custody::Coordinate {
			role,
			key: custody::FieldKey::new(slot, generation),
		};
		let keys: alloc::vec::Vec<_> = core::iter::once(coordinate(
			custody::Role::SessionAccess,
			origin.source.slot(),
			origin.source.generation(),
		))
		.chain(
			origin
				.files
				.as_slice()
				.iter()
				.map(|file| coordinate(custody::Role::SourceBlob, file.source.slot(), file.source.generation())),
		)
		.collect();
		release_sources(record, &keys);
	}
}
impl Origin {
	pub fn validate<R: custody::References>(&self, held: &custody::Custody<R>) -> bool {
		crate::room::message::LineId::new(self.id.get()).is_some()
			&& held.line(self.line).is_some()
			&& held.session_access(self.source).is_some()
			&& self.from.text().as_str().is_some_and(crate::room::inbox::valid_nick)
			&& self
				.files
				.as_slice()
				.iter()
				.all(|file| held.source_blob(file.source).is_some() && file.description.file().is_ok())
	}
}

/// Only private settlement accepts this plan. Existing file coordinates select
/// retained custody; new files select exact source fields in the effect receipt.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Update {
	pub origin: Origin,
	pub existing: bool,
	pub files: List<FileSource, { crate::room::line::MAX_MESSAGE_FILES }>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum FileSource {
	Retained(custody::FieldKey<custody::SourceBlob>),
	Submitted(usize),
}
impl Update {
	/// Future strong fields reserved before dispatch. Existing file sources
	/// retain their original occurrences and spend no additional field slots.
	pub fn reserved(&self) -> impl Iterator<Item = custody::Coordinate> + '_ {
		let coordinate = |role, slot, generation| custody::Coordinate {
			role,
			key: custody::FieldKey::new(slot, generation),
		};
		core::iter::once(coordinate(
			custody::Role::Line,
			self.origin.line.slot(),
			self.origin.line.generation(),
		))
		.chain(core::iter::once(coordinate(
			custody::Role::SessionAccess,
			self.origin.source.slot(),
			self.origin.source.generation(),
		)))
		.filter(|_| !self.existing)
		.chain(
			self.origin
				.files
				.as_slice()
				.iter()
				.zip(self.files.as_slice())
				.filter(|(_, selected)| matches!(selected, FileSource::Submitted(_)))
				.map(move |(file, _)| {
					coordinate(custody::Role::SourceBlob, file.source.slot(), file.source.generation())
				}),
		)
	}
}
