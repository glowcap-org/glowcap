//! Bounded record codecs for workspace intent, typed custody and effect receipts.
//! Capability bytes belong to shared hosting. These payloads contain only data
//! and coordinates paired with separately retained strong reference fields.
mod effects;
mod pages;
use super::{
	custody::{self, Coordinate, Custody, References, Retained, RetainedField},
	workspace::Intent,
};
use alloc::vec::Vec;
pub use effects::{decode_effect, encode_effect};
use serde::{Deserialize, Serialize};

pub const PAGE_BYTES: usize = 48 * 1024;
pub const FIELDS_PER_PAGE: usize = 64;
pub const MAX_PAGES: usize = 64;
/// Register the complete family before opening storage. A payload page leaves
/// room for its envelope and bounded strong edges in the 64 KiB Store record.
#[derive(Clone, Copy)]
pub struct Schema {
	pub id: u64,
	pub version: u32,
	pub max_payload: usize,
	pub max_edges: usize,
}
pub const WORKSPACE: Schema = Schema {
	id: u64::from_be_bytes(*b"ROOMSW01"),
	version: super::VERSION as u32,
	max_payload: PAGE_BYTES,
	max_edges: MAX_PAGES + 1,
};
pub const CUSTODY: Schema = Schema {
	id: u64::from_be_bytes(*b"ROOMSC01"),
	version: super::VERSION as u32,
	max_payload: PAGE_BYTES,
	max_edges: FIELDS_PER_PAGE + 1,
};
pub const EFFECT: Schema = Schema {
	id: u64::from_be_bytes(*b"ROOMSE01"),
	version: super::VERSION as u32,
	max_payload: PAGE_BYTES,
	max_edges: custody::MAX_TARGET_FIELDS + custody::MAX_RESULT_FIELDS + 2,
};
pub const SCHEMAS: &[Schema] = &[WORKSPACE, CUSTODY, EFFECT];

#[derive(Debug)]
pub enum Error {
	Capacity,
	Format,
	Fields,
	Json(serde_json::Error),
}
impl From<serde_json::Error> for Error {
	fn from(value: serde_json::Error) -> Self {
		Self::Json(value)
	}
}

pub struct Page<'a, R: References> {
	pub payload: Vec<u8>,
	/// Ordered fields borrow the original custody through shared save preparation.
	pub fields: Vec<Retained<'a, R>>,
}
/// Hosting restores exact strong fields before providing this input. The codec
/// checks role, slot, generation and count; it never looks up a publication.
pub struct RestoredPage<R: References> {
	pub payload: Vec<u8>,
	pub fields: Vec<RetainedField<R>>,
}

/// One complete candidate. The hosting owner stages these pages, their strong
/// fields and the resource binding in one transaction before publishing success.
pub struct Encoded<'a, R: References, C> {
	pub binding: &'a custody::ResourceBinding<C>,
	pub workspace: Vec<Vec<u8>>,
	pub custody: Vec<Page<'a, R>>,
	pub effects: Vec<Vec<Page<'a, R>>>,
}
pub fn encode<R: References, C>(record: &super::workspace::Record<R, C>) -> Result<Encoded<'_, R, C>, Error> {
	record.intent.validate(&record.custody).map_err(|_| Error::Fields)?;
	for (index, receipt) in record.effects.0.iter().enumerate() {
		if record.effects.0[..index]
			.iter()
			.any(|prior| prior.operation == receipt.operation)
		{
			return Err(Error::Format);
		}
	}
	let output = Encoded {
		binding: &record.binding,
		workspace: encode_workspace(&record.intent)?,
		custody: encode_custody(&record.custody)?,
		effects: record.effects.0.iter().map(encode_effect).collect::<Result<_, _>>()?,
	};
	check_budget(
		output
			.workspace
			.iter()
			.map(Vec::as_slice)
			.chain(output.custody.iter().map(|p| p.payload.as_slice()))
			.chain(output.effects.iter().flatten().map(|p| p.payload.as_slice())),
	)?;
	Ok(output)
}
pub fn decode<R: References, C>(
	binding: custody::ResourceBinding<C>,
	workspace: &[&[u8]],
	custody: Vec<RestoredPage<R>>,
	effects: Vec<Vec<RestoredPage<R>>>,
) -> Result<super::workspace::Record<R, C>, Error> {
	if effects.len() > custody::MAX_EFFECTS {
		return Err(Error::Capacity);
	}
	check_budget(
		workspace
			.iter()
			.copied()
			.chain(custody.iter().map(|p| p.payload.as_slice()))
			.chain(effects.iter().flatten().map(|p| p.payload.as_slice())),
	)?;
	let effects = effects.into_iter().map(decode_effect).collect::<Result<Vec<_>, _>>()?;
	for (index, receipt) in effects.iter().enumerate() {
		if effects[..index]
			.iter()
			.any(|prior| prior.operation == receipt.operation)
		{
			return Err(Error::Format);
		}
	}
	let record = super::workspace::Record {
		binding,
		intent: decode_workspace(workspace)?,
		custody: decode_custody(custody)?,
		effects: crate::fields::List::new(effects).ok_or(Error::Capacity)?,
	};
	record.intent.validate(&record.custody).map_err(|_| Error::Fields)?;
	Ok(record)
}

pub fn encode_workspace(intent: &Intent) -> Result<Vec<Vec<u8>>, Error> {
	pages::encode(WORKSPACE.id, &serde_json::to_vec(intent)?)
}
pub fn decode_workspace(payloads: &[&[u8]]) -> Result<Intent, Error> {
	let bytes = pages::decode(WORKSPACE.id, payloads)?;
	let raw = core::str::from_utf8(&bytes).map_err(|_| Error::Format)?;
	Intent::decode(raw).map_err(|e| match e {
		super::workspace::DecodeError::Capacity => Error::Capacity,
		super::workspace::DecodeError::Json(e) => Error::Json(e),
	})
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Fields {
	version: super::workspace::Version,
	coordinates: crate::fields::List<Coordinate, FIELDS_PER_PAGE>,
}

pub fn encode_custody<R: References>(custody: &Custody<R>) -> Result<Vec<Page<'_, R>>, Error> {
	let mut fields = custody.fields().peekable();
	let mut output = Vec::new();
	// The empty table still has a versioned payload.
	loop {
		let held: Vec<_> = fields.by_ref().take(FIELDS_PER_PAGE).collect();
		let coordinates = held.iter().map(Retained::coordinate).collect();
		let data = Fields {
			version: super::workspace::Version::V1,
			coordinates: crate::fields::List::new(coordinates).ok_or(Error::Capacity)?,
		};
		let payloads = pages::encode(CUSTODY.id, &serde_json::to_vec(&data)?)?;
		if payloads.len() != 1 {
			return Err(Error::Capacity);
		}
		output.push(Page {
			payload: payloads.into_iter().next().expect("one field page"),
			fields: held,
		});
		if fields.peek().is_none() {
			break;
		}
	}
	Ok(output)
}
pub fn decode_custody<R: References>(pages: Vec<RestoredPage<R>>) -> Result<Custody<R>, Error> {
	if pages.is_empty() || pages.len() > MAX_PAGES {
		return Err(Error::Capacity);
	}
	let mut custody = Custody::default();
	let mut bytes = 0usize;
	for page in pages {
		bytes = bytes.checked_add(page.payload.len()).ok_or(Error::Capacity)?;
		if bytes > custody::MAX_AUTHORITY_BYTES {
			return Err(Error::Capacity);
		}
		let body = pages::decode(CUSTODY.id, &[&page.payload])?;
		let data: Fields = serde_json::from_slice(&body)?;
		check_fields(&data.coordinates.0, &page.fields)?;
		for field in page.fields {
			custody.insert(field).map_err(|_| Error::Fields)?;
		}
	}
	Ok(custody)
}
fn check_fields<R: References>(coordinates: &[Coordinate], fields: &[RetainedField<R>]) -> Result<(), Error> {
	if coordinates.len() != fields.len()
		|| coordinates
			.iter()
			.zip(fields)
			.any(|(coordinate, field)| *coordinate != field.borrowed().coordinate())
	{
		return Err(Error::Fields);
	}
	Ok(())
}

/// The owning transaction includes all three families in this aggregate. A
/// bounded page is not a new per-record authority allowance.
pub fn check_budget<'a>(payloads: impl IntoIterator<Item = &'a [u8]>) -> Result<(), Error> {
	let mut count = 0;
	let mut bytes = 0usize;
	for payload in payloads {
		count += 1;
		bytes = bytes.checked_add(payload.len()).ok_or(Error::Capacity)?;
		if payload.len() > PAGE_BYTES || count > MAX_PAGES || bytes > custody::MAX_AUTHORITY_BYTES {
			return Err(Error::Capacity);
		}
	}
	Ok(())
}
