//! A remote feed can revise one key forever. Charge every scanned row, including
//! replacements, before retaining a page. Only expose a completed bounded scan.
use super::{Entry, Identity, Key, Page};
use crate::archive::{Error, Filter, MAX_READ, MAX_RECORDS};
use alloc::{collections::BTreeMap, sync::Arc, vec::Vec};
pub struct Scan {
	filter: Filter,
	after: u64,
	scanned: usize,
	complete: bool,
	latest: BTreeMap<Key, Arc<Entry>>,
}
impl Scan {
	pub fn new(filter: Filter) -> Result<Self, Error> {
		filter.validate()?;
		Ok(Self {
			filter,
			after: 0,
			scanned: 0,
			complete: false,
			latest: BTreeMap::new(),
		})
	}
	pub fn filter(&self) -> &Filter {
		&self.filter
	}
	pub fn after(&self) -> u64 {
		self.after
	}
	pub fn is_complete(&self) -> bool {
		self.complete
	}
	pub fn push(&mut self, page: Page) -> Result<(), Error> {
		if self.complete {
			return Err(Error::Page);
		}
		page.validate(&self.filter, self.after, MAX_READ)?;
		let scanned = self.scanned + page.records.len();
		if scanned > MAX_RECORDS || (scanned == MAX_RECORDS && page.more) {
			return Err(Error::Capacity);
		}
		for entry in page.records {
			// BTreeMap::insert preserves an existing key. Remove it first so an
			// edited/withdrawn record cannot remain retained through its old key.
			self.latest.remove(entry.record.as_ref() as &dyn Identity);
			self.latest.insert(Key(entry.record.clone()), entry);
		}
		self.scanned = scanned;
		self.after = page.next;
		self.complete = !page.more;
		Ok(())
	}
	pub fn finish(self) -> Result<Vec<Arc<Entry>>, Error> {
		if !self.complete {
			return Err(Error::Page);
		}
		let mut entries: Vec<_> = self.latest.into_values().collect();
		entries.sort_unstable_by_key(|entry| entry.revision);
		Ok(entries)
	}
}
