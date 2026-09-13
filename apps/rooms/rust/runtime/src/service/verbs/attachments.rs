//! `archivedAttachment`: a bounded reader over one file kept in the session's
//! archive, minted on the caller's session.
use crate::archive::session::SessionArchive;
use crate::service::Platform;
use crate::service::authority::{Authority, HistoryAccess};
use crate::service::error::Error;
use crate::service::events::read_bounds;
use crate::service::facet::Facet;
use glowcap::{Argument, current_session};
use rooms_application::{
	archive::{Filter, Record, protocol},
	room::line::MAX_MESSAGE_FILES,
	session::verbs,
};
use rooms_glowcap::Value;
use std::{cell::Cell, rc::Rc};

/// Live archived-file readers held through one attached connection.
const MAX_READERS: u32 = 512;

pub(in crate::service) fn archived<P: Platform>(
	facet: &Facet<P>,
	authority: &Authority,
	args: &[Argument],
) -> Result<Argument, Error> {
	let access = HistoryAccess::new(facet, authority)?;
	access.check_file()?;
	let (record, index) = match args {
		[row, Argument::Integer(index)] => {
			let index = attachment_index(*index).ok_or_else(|| {
				Error::invalid("archivedAttachment file index is outside the retained attachment range")
			})?;
			let record = protocol::record(&Value(row)).map_err(Error::invalid_by)?;
			(record, index)
		}
		_ => {
			return Err(Error::invalid(
				"archivedAttachment takes one archive line and file index",
			));
		}
	};
	let session =
		current_session()?.ok_or_else(|| Error::invalid("a Rooms session facet is reachable only over a session"))?;
	let permit = {
		let mut readers = facet.0.attachment_reads.borrow_mut();
		readers.retain(|(held, _)| held.is_open());
		let at = match readers.iter().position(|(held, _)| held.same_session(&session)) {
			Some(at) => at,
			None => {
				readers.push((session.borrowed(), Rc::new(Cell::new(0))));
				readers.len() - 1
			}
		};
		if readers[at].1.get() >= MAX_READERS {
			return Err(Error::exhausted(
				"this attached view reached its archived-file reader ceiling",
			));
		}
		let count = readers[at].1.clone();
		count.set(count.get() + 1);
		ReaderPermit(count)
	};
	let reader = ArchivedFile::new(facet, access, record, index, permit)?;
	let answers = facet.0.answers.clone();
	let report = facet.0.report.clone();
	Ok(session
		.spawn_owned(move |verb, args| {
			if verb != verbs::READ {
				return Err(Error::invalid("archived file supports only read").into_refusal());
			}
			let (offset, maximum) = read_bounds(args)
				.ok_or_else(|| Error::invalid("archived file read takes a bounded offset and length").into_refusal())?;
			let reader = reader.clone();
			answers
				.later(report.clone(), verbs::READ, async move {
					Ok(Argument::Bytes(reader.read(offset, maximum).await?))
				})
				.map_err(Error::into_refusal)
		})?
		.into())
}

fn attachment_index(value: i64) -> Option<usize> {
	usize::try_from(value).ok().filter(|index| *index < MAX_MESSAGE_FILES)
}

struct ReaderPermit(Rc<Cell<u32>>);
impl Drop for ReaderPermit {
	fn drop(&mut self) {
		self.0.set(self.0.get() - 1);
	}
}

/// Local and wire readers retain the same live authority and exact record.
#[derive(Clone)]
pub struct ArchivedFile<P: Platform>(Rc<Reader<P>>);
struct Reader<P: Platform> {
	_permit: ReaderPermit,
	access: HistoryAccess<P>,
	archive: Rc<SessionArchive<P>>,
	record: Record,
	index: usize,
	digest: String,
}
impl<P: Platform> ArchivedFile<P> {
	fn new(
		facet: &Facet<P>,
		access: HistoryAccess<P>,
		record: Record,
		index: usize,
		permit: ReaderPermit,
	) -> Result<Self, Error> {
		access.check_file()?;
		let digest = rooms_application::archive::blobs::files(&record)
			.map_err(Error::invalid_by)?
			.get(index)
			.and_then(|attachment| attachment.blob())
			.ok_or_else(|| Error::stale("archivedAttachment names no retained file bytes"))?
			.to_owned();
		Ok(Self(Rc::new(Reader {
			_permit: permit,
			access,
			archive: facet.0.archive.clone(),
			record,
			index,
			digest,
		})))
	}
	pub(in crate::service) fn local(facet: &Facet<P>, record: Record, index: usize) -> Result<Self, Error> {
		let access = HistoryAccess::new(facet, &Authority::Admin)?;
		let count = facet.0.local_file_reads.clone();
		if count.get() >= MAX_READERS {
			return Err(Error::exhausted("local archived-file reader ceiling reached"));
		}
		count.set(count.get() + 1);
		Self::new(facet, access, record, index, ReaderPermit(count))
	}
	pub fn description(&self) -> &rooms_application::archive::Attachment {
		&rooms_application::archive::blobs::files(&self.0.record).expect("admitted line")[self.0.index]
	}
	pub async fn read(&self, offset: u64, maximum: usize) -> Result<Vec<u8>, Error> {
		self.0.access.check_file()?;
		if maximum == 0 || maximum > rooms_application::files::CHUNK_BYTES {
			return Err(Error::invalid("archived file read takes a bounded offset and length"));
		}
		let record = &self.0.record;
		let filter = Filter {
			source: Some(record.coordinates().source.clone()),
			generation: Some(record.coordinates().generation.clone()),
			kind: Some(record.kind()),
			conversation_kind: record.conversation_kind(),
			directory: Some(record.directory().clone()),
			conversation: Some(record.conversation().clone()),
			digest: Some(self.0.digest.clone()),
		};
		let rows = self.0.archive.read(filter)?.wait().await?;
		let gone = || Error::stale("those archived file bytes are no longer available");
		// A digest can occur in several lines and positions. It is content,
		// not the identity of the record that admitted this reader.
		let kept = rows
			.into_iter()
			.find(|kept| kept.record.coordinates() == record.coordinates())
			.ok_or_else(gone)?;
		let metadata = rooms_application::archive::blobs::files(&kept.record)
			.map_err(|_| gone())?
			.get(self.0.index)
			.ok_or_else(gone)?;
		if !metadata.metadata_matches(self.description()) || metadata.blob() != Some(self.0.digest.as_str()) {
			return Err(gone());
		}
		let blob = kept.blob(self.0.index).await?.ok_or_else(gone)?;
		let bytes = blob.read(offset, maximum).await?;
		self.0.access.check_file()?;
		Ok(bytes)
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn archived_attachment_index_is_portable_and_semantically_bounded() {
		assert_eq!(attachment_index(-1), None);
		assert_eq!(attachment_index(0), Some(0));
		assert_eq!(
			attachment_index((MAX_MESSAGE_FILES - 1) as i64),
			Some(MAX_MESSAGE_FILES - 1)
		);
		assert_eq!(attachment_index(MAX_MESSAGE_FILES as i64), None);
		assert_eq!(attachment_index(i64::MAX), None);
	}
}
