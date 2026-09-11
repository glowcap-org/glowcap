//! Exact archive passable tuples. Validation retains no capability, and checks
//! row/page bounds before allocating their owned record representation.
use super::*;
use crate::{files::FileArgument, room::ListArgument};
use alloc::{string::String, sync::Arc, vec::Vec};
pub const PUT: &str = "put";
pub const READ: &str = "read";
pub const NARROW: &str = "narrow";
fn item<A: ListArgument>(row: &A, at: usize) -> Result<A, Error> {
	row.at(at).ok_or(Error::Record)
}
fn text<A: ListArgument>(row: &A, at: usize, limit: usize, empty: bool) -> Result<String, Error> {
	let value = item(row, at)?;
	let value = value.text().ok_or(Error::Record)?;
	records::bounded(value, limit, empty)?;
	Ok(value.into())
}
fn document<A: ListArgument>(
	row: &A,
	at: usize,
	limit: usize,
	empty: bool,
) -> Result<crate::text::DocumentText, Error> {
	let value = item(row, at)?.document(limit).ok_or(Error::Record)?;
	records::bounded_text(&value, limit, empty)?;
	Ok(value)
}
fn optional_document<A: ListArgument>(
	row: &A,
	at: usize,
	max: usize,
) -> Result<Option<crate::text::DocumentText>, Error> {
	if item(row, at)?.is_null() {
		Ok(None)
	} else {
		document(row, at, max, false).map(Some)
	}
}
fn number<A: ListArgument>(row: &A, at: usize, positive: bool) -> Result<u64, Error> {
	let number = u64::try_from(item(row, at)?.integer().ok_or(Error::Record)?).map_err(|_| Error::Record)?;
	records::safe(number, positive)?;
	Ok(number)
}
fn optional<A: ListArgument>(row: &A, at: usize, max: usize) -> Result<Option<String>, Error> {
	if item(row, at)?.is_null() {
		Ok(None)
	} else {
		text(row, at, max, false).map(Some)
	}
}
fn conversation(value: &str) -> Result<ConversationKind, Error> {
	match value {
		"room" => Ok(ConversationKind::Room),
		"direct" => Ok(ConversationKind::Direct),
		_ => Err(Error::Record),
	}
}
pub fn record<A: ListArgument>(row: &A) -> Result<Record, Error> {
	record_at(row, 0)
}
fn record_at<A: ListArgument>(row: &A, offset: usize) -> Result<Record, Error> {
	let count = row
		.list_len()
		.ok_or(Error::Record)?
		.checked_sub(offset)
		.ok_or(Error::Record)?;
	let tag = item(row, offset)?;
	let standing = match (tag.text(), count) {
		(Some("standing"), 8) => true,
		(Some("line"), 14) => false,
		_ => return Err(Error::Record),
	};
	let coordinates = Coordinates {
		source: document(row, offset + 1, MAX_ID_BYTES, false)?,
		generation: document(row, offset + 2, MAX_ID_BYTES, false)?,
		id: document(row, offset + 3, MAX_ID_BYTES, false)?,
	};
	let directory = document(row, offset + if standing { 4 } else { 5 }, MAX_CONTEXT_BYTES, false)?;
	let body = if standing {
		Body::Standing {
			room: document(row, offset + 5, MAX_CONVERSATION_BYTES, false)?,
			nick: document(row, offset + 6, 128, false)?,
			at: number(row, offset + 7, false)?,
		}
	} else {
		let kind = item(row, offset + 4)?;
		let kind = conversation(kind.text().ok_or(Error::Record)?)?;
		let state = item(row, offset + 12)?;
		let state = match state.text().ok_or(Error::Record)? {
			"present" => LineState::Present,
			"edited" => LineState::Edited,
			"withdrawn" => LineState::Withdrawn,
			_ => return Err(Error::Record),
		};
		let files = item(row, offset + 13)?;
		let count = files
			.list_len()
			.filter(|n| *n <= crate::room::line::MAX_MESSAGE_FILES)
			.ok_or(Error::Record)?;
		let mut attachments = Vec::with_capacity(count);
		for at in 0..count {
			let file = item(&files, at)?;
			if file.list_len() != Some(6) {
				return Err(Error::Record);
			}
			let width = number(&file, 3, false)?;
			let height = number(&file, 4, false)?;
			if width > 65535 || height > 65535 {
				return Err(Error::Record);
			}
			attachments.push(Attachment::new(
				document(&file, 0, 480, false)?,
				document(&file, 1, 240, true)?,
				number(&file, 2, false)?,
				width,
				height,
				optional(&file, 5, 64)?,
			)?);
		}
		Body::Line {
			conversation_kind: kind,
			conversation: document(row, offset + 6, MAX_CONVERSATION_BYTES, false)?,
			from: document(row, offset + 7, 128, false)?,
			text: document(row, offset + 8, crate::room::line::MAX_LINE_BYTES, true)?,
			mine: item(row, offset + 9)?.boolean().ok_or(Error::Record)?,
			at: number(row, offset + 10, false)?,
			order: number(row, offset + 11, true)?,
			state,
			attachments,
		}
	};
	Record::new(coordinates, directory, body)
}
pub fn filter<A: ListArgument>(row: &A) -> Result<Filter, Error> {
	if row.list_len() != Some(7) {
		return Err(Error::Filter);
	}
	let kind = optional(row, 2, 8)?
		.map(|s| match s.as_str() {
			"standing" => Ok(Kind::Standing),
			"line" => Ok(Kind::Line),
			_ => Err(Error::Filter),
		})
		.transpose()?;
	let conversation_kind = optional(row, 3, 6)?.map(|s| conversation(&s)).transpose()?;
	let filter = Filter {
		source: optional_document(row, 0, MAX_ID_BYTES)?,
		generation: optional_document(row, 1, MAX_ID_BYTES)?,
		kind,
		conversation_kind,
		directory: optional_document(row, 4, MAX_CONTEXT_BYTES)?,
		conversation: optional_document(row, 5, MAX_CONVERSATION_BYTES)?,
		digest: optional(row, 6, 64)?,
	};
	filter.validate()?;
	Ok(filter)
}
pub fn read_limit(value: &impl FileArgument) -> Result<usize, Error> {
	let value = value.natural().filter(|value| *value != 0).ok_or(Error::Page)?;
	Ok(value.min(MAX_READ as u64) as usize)
}
pub fn page<A: ListArgument>(row: &A, filter: &Filter, after: u64, limit: usize) -> Result<index::Page, Error> {
	filter.validate()?;
	records::safe(after, false)?;
	if row.list_len() != Some(3) || limit == 0 {
		return Err(Error::Page);
	}
	let next = number(row, 0, false)?;
	let more = item(row, 1)?.boolean().ok_or(Error::Page)?;
	let rows = item(row, 2)?;
	let limit = limit.min(MAX_READ);
	let count = rows.list_len().filter(|n| *n <= limit).ok_or(Error::Page)?;
	let mut records = Vec::with_capacity(count);
	for at in 0..count {
		let row = item(&rows, at)?;
		let revision = number(&row, 0, true)?;
		records.push(Arc::new(index::Entry {
			revision,
			record: Arc::new(record_at(&row, 1)?),
		}));
	}
	let page = index::Page { next, more, records };
	page.validate(filter, after, limit)?;
	Ok(page)
}
