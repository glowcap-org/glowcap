//! Build the existing passable rows through the binding's own value constructors.
use super::*;
use crate::room::BuildArguments;
use alloc::{vec, vec::Vec};
pub fn record<O: BuildArguments>(record: &Record) -> Vec<O::Value> {
	let mut row = Vec::with_capacity(if record.kind() == Kind::Standing { 8 } else { 15 });
	append::<O>(record, &mut row);
	row
}
fn append<O: BuildArguments>(record: &Record, row: &mut Vec<O::Value>) {
	let c = record.coordinates();
	row.extend([
		O::text(if record.kind() == Kind::Standing {
			"standing"
		} else {
			"line"
		}),
		O::document(&c.source),
		O::document(&c.generation),
		O::document(&c.id),
	]);
	match record.body() {
		Body::Standing { room, nick, at } => row.extend([
			O::document(record.directory()),
			O::document(room),
			O::document(nick),
			O::integer(*at),
		]),
		Body::Line {
			conversation_kind,
			conversation,
			from,
			text,
			mine,
			at,
			order,
			state,
			previews,
			attachments,
		} => {
			row.extend([
				O::text(conversation_kind.wire()),
				O::document(record.directory()),
				O::document(conversation),
				O::document(from),
				O::document(text),
				O::boolean(*mine),
				O::integer(*at),
				O::integer(*order),
				O::text(state.wire()),
			]);
			row.push(O::list(
				attachments
					.iter()
					.map(|a| {
						let d = a;
						let (width, height) = d.dimensions();
						O::list(vec![
							O::document(d.name()),
							O::document(d.mime()),
							O::integer(d.size() as u64),
							O::integer(width as u64),
							O::integer(height as u64),
							a.blob().map_or_else(O::null, O::text),
						])
					})
					.collect(),
			));
			row.push(O::list(previews.urls().iter().map(|url| O::text(url)).collect()));
		}
	}
}
pub fn filter<O: BuildArguments>(filter: &Filter) -> Result<O::Value, Error> {
	filter.validate()?;
	let optional = |s: Option<&str>| s.map_or_else(O::null, O::text);
	Ok(O::list(vec![
		filter.source.as_ref().map_or_else(O::null, O::document),
		filter.generation.as_ref().map_or_else(O::null, O::document),
		optional(
			filter
				.kind
				.map(|kind| if kind == Kind::Standing { "standing" } else { "line" }),
		),
		optional(filter.conversation_kind.map(ConversationKind::wire)),
		filter.directory.as_ref().map_or_else(O::null, O::document),
		filter.conversation.as_ref().map_or_else(O::null, O::document),
		optional(filter.digest.as_deref()),
	]))
}
pub fn page<O: BuildArguments>(
	page: &index::Page,
	filter: &Filter,
	after: u64,
	limit: usize,
) -> Result<O::Value, Error> {
	page.validate(filter, after, limit.min(MAX_READ))?;
	Ok(O::list(vec![
		O::integer(page.next),
		O::boolean(page.more),
		O::list(
			page.records
				.iter()
				.map(|entry| {
					let mut row = Vec::with_capacity(16);
					row.push(O::integer(entry.revision));
					append::<O>(&entry.record, &mut row);
					O::list(row)
				})
				.collect(),
		),
	]))
}
