//! Admitted effects retain physical room for sender settlement and diagnostics.
use super::super::{custody::Outcome, workspace};
use super::*;
use alloc::collections::BTreeSet;

// A direct upload result has at most 4096 failure units, three 128-unit history
// fields, a coordinate and scalar flags. Its JSON is itself stored as a JSON
// string: each UTF-16 unit costs at most six bytes, then quoting doubles escapes.
// 2 * 6 * (4096 + 3 * 128) + 1024 fits in 64 KiB. One returned line coordinate
// and the receipt fragmentation headers fit in the remaining allowance.
const RESULT_GROWTH: usize = 64 * 1024;
// Every unresolved receipt can acquire a terminal diagnostic. Its bounded
// reason is encoded once, with at most six JSON bytes per UTF-16 unit, plus
// the field and outcome envelope. Sender reservations already cover this cost.
const OBSERVATION_GROWTH: usize = 6 * custody::MAX_OBSERVATION_REASON_UNITS + 64;
const HEADER: usize = 14;
const BODY: usize = PAGE_BYTES - HEADER;

fn size(value: &impl Serialize) -> Result<usize, Error> {
	Ok(serde_json::to_vec(value)?.len())
}
fn role(key: Coordinate) -> usize {
	key.role.index()
}
fn slot(key: Coordinate) -> (usize, u64) {
	(role(key), key.key.slot().get())
}

/// Serialization measures one bounded provenance or displayed line at a time.
/// Each temporary byte vector dies before measuring the next plan. It creates
/// no shadow graph or capability copies. At most eight plans and eighty future
/// fields are scanned. A fixed worst-case origin charge would deny otherwise
/// valid posts with small metadata at the existing aggregate profile.
/// Every content transaction preserves these reservations, including imports
/// and local edits made while an upstream effect is pending.
/// Other unresolved receipts reserve bounded diagnostic growth without a
/// capability inventory, provenance encoding or custody-slot allocation.
pub fn check_reservations<'a, R: References, C>(
	record: &super::super::workspace::Record<R, C>,
	payloads: impl IntoIterator<Item = &'a [u8]>,
) -> Result<(), Error> {
	check_sizes(
		record,
		payloads.into_iter().map(|payload| {
			(
				u64::from_be_bytes(
					payload
						.get(..8)
						.and_then(|bytes| bytes.try_into().ok())
						.unwrap_or([0; 8]),
				),
				payload.len(),
			)
		}),
	)
}
pub(super) fn check_sizes<R: References, C>(
	record: &super::super::workspace::Record<R, C>,
	payloads: impl IntoIterator<Item = (u64, usize)>,
) -> Result<(), Error> {
	let pending: Vec<_> = record
		.effects
		.as_slice()
		.iter()
		.filter(|effect| matches!(effect.outcome, Outcome::Unresolved))
		.filter_map(|effect| effect.outgoing.as_ref())
		.collect();
	let observations = record
		.effects
		.as_slice()
		.iter()
		.filter(|effect| matches!(effect.outcome, Outcome::Unresolved) && effect.outgoing.is_none())
		.count();
	if pending.is_empty() && observations == 0 {
		return Ok(());
	}
	let mut counts = [0; custody::Role::ALL.len()];
	let mut slots = BTreeSet::new();
	if !pending.is_empty() {
		for field in record.custody.fields() {
			let key = field.coordinate();
			counts[role(key)] += 1;
			slots.insert(slot(key));
		}
	}
	let mut extra_fields = 0;
	let mut origins = 0;
	let mut lines = 0;
	let mut posts = 0;
	for update in &pending {
		if update.files.as_slice().len() != update.origin.files.as_slice().len() {
			return Err(Error::Fields);
		}
		for key in update.reserved() {
			if record.custody.next_identity().get() != 0
				&& key.key.generation().get() >= record.custody.next_identity().get()
			{
				return Err(Error::Fields);
			}
			if !slots.insert(slot(key)) {
				return Err(Error::Fields);
			}
			counts[role(key)] += 1;
			extra_fields += 1;
		}
		origins += size(&update.origin)? + 1;
		if !update.existing {
			posts += 1;
			lines += size(&workspace::PostedLine {
				id: update.origin.id,
				handle: update.origin.line,
			})? + 1;
		}
	}
	if counts.iter().any(|count| *count > custody::MAX_FIELDS_PER_ROLE)
		|| record.custody.len() + extra_fields > custody::MAX_CUSTODY_FIELDS
		|| record.outgoing.as_slice().len() + posts > custody::MAX_FIELDS_PER_ROLE
	{
		return Err(Error::Capacity);
	}
	for conversation in record.intent.conversations.as_slice() {
		if let workspace::Conversation::Direct(direct) = conversation {
			let added = pending
				.iter()
				.filter(|update| !update.existing && update.origin.conversation == direct.id)
				.count();
			if direct.lines.as_slice().len() + added > custody::MAX_FIELDS_PER_ROLE {
				return Err(Error::Capacity);
			}
		}
	}
	let mut bytes = 0;
	let mut pages = 0;
	let mut workspace_bytes = 0;
	let mut workspace_pages = 0;
	let mut outgoing_bytes = 0;
	let mut outgoing_pages = 0;
	for (schema, length) in payloads {
		bytes += length;
		pages += 1;
		if schema == WORKSPACE.id {
			workspace_bytes += length.checked_sub(HEADER).ok_or(Error::Format)?;
			workspace_pages += 1;
		}
		if schema == PROVENANCE.id {
			outgoing_bytes += length.checked_sub(HEADER).ok_or(Error::Format)?;
			outgoing_pages += 1;
		}
	}
	let custody_pages = (record.custody.len() + extra_fields).max(1).div_ceil(FIELDS_PER_PAGE)
		- record.custody.len().max(1).div_ceil(FIELDS_PER_PAGE);
	let workspace_growth = (workspace_bytes + lines).div_ceil(BODY).max(1) - workspace_pages;
	let private_envelope = if !pending.is_empty() && outgoing_pages == 0 {
		super::provenance::EMPTY_BYTES
	} else {
		0
	};
	let outgoing_growth = if pending.is_empty() {
		0
	} else {
		(outgoing_bytes + origins + private_envelope).div_ceil(BODY).max(1) - outgoing_pages
	};
	// Each added custody coordinate is below 96 bytes; a page envelope and the
	// two growing sequence scalars are below 160 bytes. Terminal effect pages
	// may keep every admitted target, while adding the bounded result above.
	let effect_pages = pending.len() * (RESULT_GROWTH.div_ceil(BODY) + 1);
	let observation_pages = observations * (OBSERVATION_GROWTH.div_ceil(BODY) + 1);
	let growth = custody_pages + workspace_growth + outgoing_growth + effect_pages + observation_pages;
	bytes += extra_fields * 96
		+ custody_pages * 160
		+ 20 + lines
		+ origins
		+ private_envelope
		+ pending.len() * RESULT_GROWTH
		+ observations * OBSERVATION_GROWTH
		+ HEADER * growth;
	if pages + growth > MAX_PAGES || bytes > custody::MAX_AUTHORITY_BYTES {
		return Err(Error::Capacity);
	}
	Ok(())
}
