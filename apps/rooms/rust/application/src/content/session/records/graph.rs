//! The session's ordered graph shape, independent of storage and transport.
use super::super::custody::{Coordinate, References, RetainedField};
use super::{CUSTODY, EFFECT, Error, MAX_PAGES, PROVENANCE, WORKSPACE, custody, effects, pages};
use alloc::vec::Vec;

/// A prepared payload and its separately held field count. Root is workspace
/// fragment zero. Subsequent fragments, custody pages and receipts follow.
#[derive(Clone, Copy)]
pub struct GraphPage<'a> {
	pub schema: u64,
	pub version: u32,
	pub payload: &'a [u8],
	pub field_count: usize,
}

pub fn decode_graph<R: References, C>(
	binding: custody::ResourceBinding<C>,
	input: &[GraphPage<'_>],
	mut restore: impl FnMut(usize, Coordinate, usize) -> Result<RetainedField<R>, Error>,
) -> Result<super::super::workspace::Record<R, C>, Error> {
	super::check_budget(input.iter().map(|page| page.payload))?;
	if input.is_empty() || input.len() > MAX_PAGES {
		return Err(Error::Capacity);
	}
	for page in input {
		if page.version != u32::from(super::super::VERSION) {
			return Err(Error::Format);
		}
	}
	let workspace_len = group(input, 0, WORKSPACE.id)?;
	if input[..workspace_len].iter().any(|page| page.field_count != 0) {
		return Err(Error::Fields);
	}
	let payloads: Vec<_> = input[..workspace_len].iter().map(|page| page.payload).collect();
	let (intent, fence) = super::decode_workspace(&payloads)?;
	let mut at = workspace_len;
	let mut custody = custody::Custody::default();
	let custody_start = at;
	while input.get(at).is_some_and(|page| page.schema == CUSTODY.id) {
		if group(input, at, CUSTODY.id)? != 1 {
			return Err(Error::Format);
		}
		let page = input[at];
		super::restore_custody(
			&mut custody,
			page.payload,
			page.field_count,
			at == custody_start,
			|coordinate, index| restore(at, coordinate, index),
		)?;
		at += 1;
	}
	if at == custody_start {
		return Err(Error::Format);
	}
	let count = if input.get(at).is_some_and(|page| page.schema == PROVENANCE.id) {
		group(input, at, PROVENANCE.id)?
	} else {
		0
	};
	if input[at..at + count].iter().any(|page| page.field_count != 0) {
		return Err(Error::Fields);
	}
	let payloads: Vec<_> = input[at..at + count].iter().map(|page| page.payload).collect();
	let private = super::provenance::decode(&payloads)?;
	super::check_outgoing(&private.outgoing, &custody)?;
	super::provenance::check_bridges(&private.bridges, &custody)?;
	at += count;
	let mut receipts = Vec::new();
	while at < input.len() {
		if receipts.len() == custody::MAX_EFFECTS {
			return Err(Error::Capacity);
		}
		let count = group(input, at, EFFECT.id)?;
		if input[at + 1..at + count].iter().any(|page| page.field_count != 0) {
			return Err(Error::Fields);
		}
		let payloads: Vec<_> = input[at..at + count].iter().map(|page| page.payload).collect();
		let receipt = effects::restore(&payloads, input[at].field_count, |coordinate, index| {
			restore(at, coordinate, index)
		})?;
		if receipts
			.iter()
			.any(|prior: &custody::EffectReceipt<R>| prior.operation == receipt.operation)
		{
			return Err(Error::Format);
		}
		receipts.push(receipt);
		at += count;
	}
	intent.validate(&custody).map_err(|_| Error::Fields)?;
	let record = super::super::workspace::Record {
		binding,
		intent,
		fence,
		custody,
		outgoing: private.outgoing,
		bridges: private.bridges,
		effects: crate::fields::List::new(receipts).ok_or(Error::Capacity)?,
	};
	super::reservations::check_sizes(&record, input.iter().map(|page| (page.schema, page.payload.len())))?;
	Ok(record)
}

fn group(input: &[GraphPage<'_>], at: usize, schema: u64) -> Result<usize, Error> {
	let first = input.get(at).ok_or(Error::Format)?;
	let count = pages::fragment_count(schema, first.payload)?;
	let group = input
		.get(at..at.checked_add(count).ok_or(Error::Capacity)?)
		.ok_or(Error::Format)?;
	if group.iter().any(|page| page.schema != schema) {
		return Err(Error::Format);
	}
	// Individual codecs validate every fragment's ordering and full header.
	Ok(count)
}
