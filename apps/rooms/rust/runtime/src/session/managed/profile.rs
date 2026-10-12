//! Derive complete retained-call and encoded-row budgets at the shared owner.
use glowcap::loam::{Graph, InvocationBounds, Limits, ReferenceRequest, StagingBounds, ValueBounds};
use rooms_application::content::session::{custody, records};

/// Bound the declared input, result, graph and save shapes before opening either
/// physical backend. Resident cache windows remain independent of population.
pub fn storage_limits(
	fields: usize,
	restores: usize,
	saves: usize,
	verb_bytes: usize,
	arguments: ValueBounds,
	reply: ValueBounds,
) -> glowcap::Result<Limits> {
	let pages = records::MAX_PAGES - 1;
	let invocation = InvocationBounds {
		arguments,
		reply,
		verb_bytes,
		held_occurrences: fields.checked_add(reply.capabilities).ok_or_else(exhausted)?,
		receipt: true,
		dependent: false,
	};
	// Callback-owned codec and declaration buffers are Rust allocations. Their
	// shared copies and every Call setter/field hold are covered by these owners.
	let call_bytes = invocation
		.call_size_bound()?
		.checked_add(Graph::call_size_bound(pages, custody::MAX_AUTHORITY_BYTES, fields)?)
		.ok_or_else(exhausted)?
		.checked_add(ReferenceRequest::call_size_bound(
			restores,
			saves,
			ReferenceRequest::MAX_URI_BYTES,
		)?)
		.ok_or_else(exhausted)?;
	let managed = StagingBounds::content(1, true)?;
	let recipes = StagingBounds::references(saves)?;
	// Every registered application family may occupy any child slot. Use its
	// complete encoded envelope, not a payload allowance or a private schema ID.
	let page_bytes = records::SCHEMAS.iter().try_fold(0usize, |largest, schema| {
		let bytes = glowcap::loam::Schema {
			id: schema.id,
			version: schema.version,
			max_payload: schema.max_payload,
			max_edges: schema.max_edges,
		}
		.encoded_size_bound()?;
		Ok::<_, glowcap::Error>(largest.max(bytes))
	})?;
	let max_changes = records::MAX_PAGES
		.checked_add(managed.changes)
		.ok_or_else(exhausted)?
		.checked_add(recipes.changes)
		.ok_or_else(exhausted)?;
	let staging_bytes = records::MAX_PAGES
		.checked_mul(page_bytes)
		.ok_or_else(exhausted)?
		.checked_add(managed.staging_bytes)
		.ok_or_else(exhausted)?
		.checked_add(recipes.staging_bytes)
		.ok_or_else(exhausted)?;
	let record_bytes = page_bytes.max(managed.record_bytes).max(recipes.record_bytes);
	// A managed record window plus descriptor/directory and streamed page/recipe
	// windows. Graph population does not determine cache residency.
	let record_capacity = 8;
	let cache_slots = record_capacity + 2 + 2;
	let max_references = 16;
	Ok(Limits {
		call_bytes,
		pending_bytes: call_bytes,
		ingress_bytes: call_bytes,
		max_changes,
		staging_bytes,
		record_bytes,
		cache_slots,
		max_leases: cache_slots,
		resident_bytes: cache_slots.checked_mul(record_bytes).ok_or_else(exhausted)?,
		record_capacity,
		max_references,
		max_retentions: fields.checked_add(max_references).ok_or_else(exhausted)?,
		max_reference_saves: saves,
		..Limits::default()
	})
}
fn exhausted() -> glowcap::Error {
	glowcap::loam::refusal("Rooms storage profile exceeds addressable memory")
}

/// Shared process/tab profile. Whole-call reservations limit concurrency.
/// Backing grows with admitted work. The shared call count also admits reads,
/// callback forwarding and source checks. Effect receipts have their separate
/// application limit. Three overlapping managed windows cover issuance and
/// its exact use/control result, independently of graph population.
pub fn production_limits() -> glowcap::Result<Limits> {
	let fields = custody::MAX_CUSTODY_FIELDS
		+ custody::MAX_EFFECTS * (1 + custody::MAX_TARGET_FIELDS + custody::MAX_RESULT_FIELDS);
	let mut limits = storage_limits(
		fields,
		MAX_RESTORES,
		records::FIELDS_PER_PAGE,
		64,
		ValueBounds {
			values: 2048,
			capabilities: records::FIELDS_PER_PAGE + 4,
			bytes: custody::MAX_AUTHORITY_BYTES + 65536,
			..ValueBounds::default()
		},
		ValueBounds {
			values: 2048,
			capabilities: records::FIELDS_PER_PAGE + 4,
			bytes: custody::MAX_AUTHORITY_BYTES,
			..ValueBounds::default()
		},
	)?;
	limits.call_bytes = limits
		.call_bytes
		.checked_add(ReferenceRequest::uri_call_size_bound(
			records::FIELDS_PER_PAGE,
			ReferenceRequest::MAX_URI_BYTES,
		)?)
		.ok_or_else(exhausted)?;
	limits.record_capacity = 24;
	limits.cache_slots = 3 * (limits.record_capacity + 2) + 5;
	limits.max_leases = limits.cache_slots * limits.max_operations;
	limits.resident_bytes = limits
		.cache_slots
		.checked_mul(limits.record_bytes)
		.ok_or_else(exhausted)?;
	limits.max_references = 128;
	limits.max_retentions = fields + limits.max_references;
	reader_limits(limits)
}

/// Result acquisition restores the original source, an existing source slot,
/// and the result and existing destination for each page-sized mapping. Other
/// methods restore at most one custody page or one effect's result fields.
/// This bounds preparation requests, independently of graph population.
pub(super) const MAX_RESTORES: usize = 2 * records::FIELDS_PER_PAGE + 2;

/// Compose forwarded-result storage with the callback and graph reservation.
/// Host.Call allocates its bounded result inside the retained call's input
/// arena before forwarding. A reply limit alone does not admit that allocation.
/// The shared forwarding query owns the reply layout and physical call arena
/// overhead. Private execution/C observation budgets are independent.
pub fn reader_limits(mut limits: Limits) -> glowcap::Result<Limits> {
	let (reply_bytes, call_bytes) = reader_reply_bounds().forwarding_size_bound()?;
	limits.forward_reply_bytes = reply_bytes;
	limits.call_bytes = limits.call_bytes.checked_add(call_bytes).ok_or_else(exhausted)?;
	limits.pending_bytes = limits
		.call_bytes
		.checked_mul(limits.max_operations)
		.ok_or_else(exhausted)?;
	limits.ingress_bytes = limits.pending_bytes;
	Ok(limits)
}

/// The facade forwards the existing bounded wire tuples. Derive their physical
/// allowance at the shared value-copy owner instead of shortening application
/// pages to a transport buffer. Backing exists only while a read is in flight.
fn reader_reply_bounds() -> ValueBounds {
	use rooms_application::{archive, files, open_graph, room};
	let encoded_previews = 2 + open_graph::MAX_PREVIEWS * (6 * open_graph::MAX_URL_BYTES + 3);
	let history_bytes = room::history::MAX_BYTES + room::history::MAX_LINES * encoded_previews;
	// Each archive row carries revision plus 15 fields. Each attachment is a
	// six-field tuple, and previews are a list of at most five URL leaves.
	let row_values = 17 + 7 * room::line::MAX_MESSAGE_FILES + open_graph::MAX_PREVIEWS;
	let attachment_bytes = 3 * (files::MAX_FILE_NAME_UNITS + files::MAX_MIME_UNITS) + 64;
	let row_bytes = 3 * archive::MAX_ID_BYTES
		+ archive::MAX_CONTEXT_BYTES
		+ archive::MAX_CONVERSATION_BYTES
		+ 128 + room::line::MAX_LINE_BYTES
		+ 16 + room::line::MAX_MESSAGE_FILES * attachment_bytes
		+ open_graph::MAX_PREVIEWS * open_graph::MAX_URL_BYTES;
	ValueBounds {
		values: (4 + archive::MAX_READ * row_values).max(1 + 5 * room::history::MAX_LINES),
		bytes: (archive::MAX_READ * row_bytes)
			.max(history_bytes)
			.max(files::CHUNK_BYTES),
		capabilities: 1,
		..ValueBounds::default()
	}
}
