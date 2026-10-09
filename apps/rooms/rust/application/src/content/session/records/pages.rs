//! Versioned, ordered payload fragments. The owning graph retains every part.
use super::{Error, MAX_PAGES, PAGE_BYTES};
use alloc::vec::Vec;
const HEADER: usize = 14;
const BODY: usize = PAGE_BYTES - HEADER;
pub(super) fn fragment_count(schema: u64, payload: &[u8]) -> Result<usize, Error> {
	if payload.len() < HEADER || payload[..8] != schema.to_be_bytes() {
		return Err(Error::Format);
	}
	let count = usize::from(u16::from_be_bytes([payload[12], payload[13]]));
	if count == 0 || count > MAX_PAGES {
		return Err(Error::Format);
	}
	Ok(count)
}
pub fn encode(schema: u64, bytes: &[u8]) -> Result<Vec<Vec<u8>>, Error> {
	if bytes.len() > super::custody::MAX_AUTHORITY_BYTES {
		return Err(Error::Capacity);
	}
	let count = bytes.len().div_ceil(BODY).max(1);
	if count > MAX_PAGES {
		return Err(Error::Capacity);
	}
	let mut pages = Vec::with_capacity(count);
	for index in 0..count {
		let body = &bytes[(index * BODY).min(bytes.len())..((index + 1) * BODY).min(bytes.len())];
		let mut page = Vec::with_capacity(HEADER + body.len());
		page.extend_from_slice(&schema.to_be_bytes());
		page.extend_from_slice(&super::super::VERSION.to_be_bytes());
		page.extend_from_slice(&(index as u16).to_be_bytes());
		page.extend_from_slice(&(count as u16).to_be_bytes());
		page.extend_from_slice(body);
		pages.push(page);
	}
	Ok(pages)
}
pub fn decode(schema: u64, payloads: &[&[u8]]) -> Result<Vec<u8>, Error> {
	if payloads.is_empty() || payloads.len() > MAX_PAGES {
		return Err(Error::Capacity);
	}
	super::check_budget(payloads.iter().copied())?;
	let mut bytes = Vec::new();
	for (index, page) in payloads.iter().enumerate() {
		if page.len() < HEADER
			|| page[..8] != schema.to_be_bytes()
			|| page[8..10] != super::super::VERSION.to_be_bytes()
			|| page[10..12] != (index as u16).to_be_bytes()
			|| page[12..14] != (payloads.len() as u16).to_be_bytes()
		{
			return Err(Error::Format);
		}
		if index + 1 != payloads.len() && page.len() != PAGE_BYTES {
			return Err(Error::Format);
		}
		bytes.extend_from_slice(&page[HEADER..]);
	}
	Ok(bytes)
}
