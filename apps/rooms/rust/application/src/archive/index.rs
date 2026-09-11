//! Storage owns commitment; this index applies committed revisions and preserves
//! chronology. Its two ordered maps share immutable records without copying keys.
use super::{records::safe, ConversationKind, Error, Filter, Kind, Record, MAX_READ, MAX_RECORDS};
use crate::text::DocumentText;
use alloc::{borrow::Borrow, collections::BTreeMap, sync::Arc, vec::Vec};
use core::cmp::Ordering;
mod scan;
pub use scan::Scan;

// Borrowed structural keys avoid JSON encoding or copying contextual strings on
// every lookup. Ordering compares identity only, never mutable line contents.
pub(super) type Parts<'a> = (
	&'a DocumentText,
	&'a DocumentText,
	Kind,
	Option<ConversationKind>,
	&'a DocumentText,
	&'a DocumentText,
	&'a DocumentText,
);
pub(super) trait Identity {
	fn parts(&self) -> Parts<'_>;
}
impl Identity for Record {
	fn parts(&self) -> Parts<'_> {
		let c = self.coordinates();
		(
			&c.source,
			&c.generation,
			self.kind(),
			self.conversation_kind(),
			self.directory(),
			self.conversation(),
			&c.id,
		)
	}
}
impl Identity for super::blobs::Address {
	fn parts(&self) -> Parts<'_> {
		(
			&self.coordinates.source,
			&self.coordinates.generation,
			Kind::Line,
			Some(self.kind),
			&self.directory,
			&self.conversation,
			&self.coordinates.id,
		)
	}
}
impl PartialEq for dyn Identity + '_ {
	fn eq(&self, other: &Self) -> bool {
		self.parts() == other.parts()
	}
}
impl Eq for dyn Identity + '_ {}
impl PartialOrd for dyn Identity + '_ {
	fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
		Some(self.cmp(other))
	}
}
impl Ord for dyn Identity + '_ {
	fn cmp(&self, other: &Self) -> Ordering {
		self.parts().cmp(&other.parts())
	}
}
pub(super) struct Key(pub(super) Arc<Record>);
impl<'a> Borrow<dyn Identity + 'a> for Key {
	fn borrow(&self) -> &(dyn Identity + 'a) {
		self.0.as_ref()
	}
}
impl PartialEq for Key {
	fn eq(&self, other: &Self) -> bool {
		self.0.parts() == other.0.parts()
	}
}
impl Eq for Key {}
impl PartialOrd for Key {
	fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
		Some(self.cmp(other))
	}
}
impl Ord for Key {
	fn cmp(&self, other: &Self) -> Ordering {
		self.0.parts().cmp(&other.0.parts())
	}
}

pub struct Entry {
	pub revision: u64,
	pub record: Arc<Record>,
}
pub struct Page {
	pub next: u64,
	pub more: bool,
	pub records: Vec<Arc<Entry>>,
}
impl Page {
	pub fn validate(&self, filter: &Filter, after: u64, limit: usize) -> Result<(), Error> {
		filter.validate()?;
		safe(after, false)?;
		if limit == 0 || limit > MAX_READ {
			return Err(Error::Page);
		}
		safe(self.next, false)?;
		if self.next < after || self.records.len() > limit {
			return Err(Error::Page);
		}
		let mut prior = after;
		for entry in &self.records {
			if entry.revision <= prior || entry.revision > self.next || !filter.matches(&entry.record) {
				return Err(Error::Page);
			}
			prior = entry.revision;
		}
		if self.more && (self.records.len() != limit || prior != self.next || self.records.is_empty()) {
			return Err(Error::Page);
		}
		Ok(())
	}
}
pub struct Index {
	capacity: usize,
	revision: u64,
	keys: BTreeMap<Key, u64>,
	entries: BTreeMap<u64, Arc<Entry>>,
}
impl Index {
	pub fn new(capacity: usize) -> Result<Self, Error> {
		if capacity == 0 || capacity > MAX_RECORDS {
			return Err(Error::Capacity);
		}
		Ok(Self {
			capacity,
			revision: 0,
			keys: BTreeMap::new(),
			entries: BTreeMap::new(),
		})
	}
	pub fn revision(&self) -> u64 {
		self.revision
	}
	pub fn len(&self) -> usize {
		self.entries.len()
	}
	pub fn is_empty(&self) -> bool {
		self.entries.is_empty()
	}
	pub fn clear(&mut self) {
		self.keys.clear();
		self.entries.clear();
	}
	pub fn snapshot(&self) -> impl ExactSizeIterator<Item = &Arc<Entry>> {
		self.entries.values()
	}
	pub fn line(&self, address: &super::blobs::Address) -> Option<&Record> {
		self.keys
			.get(address as &dyn Identity)
			.and_then(|revision| self.entries.get(revision))
			.map(|entry| entry.record.as_ref())
	}
	pub fn matching_line(&self, filter: &Filter) -> Option<&Record> {
		self.entries
			.values()
			.map(|e| e.record.as_ref())
			.find(|record| record.kind() == Kind::Line && filter.matches(record))
	}
	pub fn get(&self, record: &Record) -> Option<&Record> {
		self.keys
			.get(record as &dyn Identity)
			.and_then(|revision| self.entries.get(revision))
			.map(|entry| entry.record.as_ref())
	}
	/// Canonicalize an ordinary metadata put before storage serializes it. Only
	/// backend-owned digests from matching prior file positions survive.
	pub fn prepare_put(&self, record: Record) -> Record {
		let prior = self.get(&record);
		record.prepare_put(prior)
	}
	pub fn retired_by(&self, record: &Record) -> Option<&Record> {
		let previous = self.keys.get(record as &dyn Identity);
		let entry = match previous {
			Some(revision) => self.entries.get(revision),
			None if self.len() == self.capacity => self.entries.first_key_value().map(|(_, entry)| entry),
			None => None,
		};
		entry.map(|entry| entry.record.as_ref())
	}
	pub fn apply(&mut self, revision: u64, mut record: Record) -> Result<Option<Arc<Record>>, Error> {
		safe(revision, true)?;
		if revision != self.revision + 1 {
			return Err(Error::Revision);
		}
		let previous = self.keys.get(&record as &dyn Identity).copied();
		if let Some(prior) = previous {
			record.preserve_chronology(&self.entries[&prior].record);
		}
		let retired = previous.or_else(|| {
			(self.len() == self.capacity).then(|| *self.entries.first_key_value().expect("full nonempty index").0)
		});
		let retired = retired.map(|revision| {
			let entry = self.entries.remove(&revision).expect("indexed revision");
			self.keys.remove(entry.record.as_ref() as &dyn Identity);
			entry.record.clone()
		});
		let record = Arc::new(record);
		self.keys.insert(Key(record.clone()), revision);
		self.entries.insert(revision, Arc::new(Entry { revision, record }));
		self.revision = revision;
		Ok(retired)
	}
	/// Failed restore leaves the current account untouched. Gaps are expected
	/// after replacement and eviction; duplicates and reordered revisions refuse.
	pub fn restore(&mut self, revision: u64, entries: Vec<Entry>) -> Result<(), Error> {
		safe(revision, false)?;
		if entries.len() > self.capacity {
			return Err(Error::Capacity);
		}
		let mut next = Self::new(self.capacity)?;
		let mut prior = 0;
		for entry in entries {
			if entry.revision <= prior || entry.revision > revision {
				return Err(Error::Revision);
			}
			if next.keys.insert(Key(entry.record.clone()), entry.revision).is_some() {
				return Err(Error::Record);
			}
			prior = entry.revision;
			next.entries.insert(entry.revision, Arc::new(entry));
		}
		next.revision = revision;
		*self = next;
		Ok(())
	}
	pub fn read(&self, filter: &Filter, after: u64, limit: usize) -> Result<Page, Error> {
		filter.validate()?;
		safe(after, false)?;
		if limit == 0 {
			return Err(Error::Page);
		}
		let limit = limit.min(MAX_READ);
		let mut matching = self
			.entries
			.range((core::ops::Bound::Excluded(after), core::ops::Bound::Unbounded))
			.map(|(_, entry)| entry)
			.filter(|entry| filter.matches(&entry.record));
		let records: Vec<_> = matching.by_ref().take(limit).cloned().collect();
		let more = matching.next().is_some();
		// A cursor already ahead of this account must never regress. This also
		// preserves a caller's position across an empty or restored account.
		let next = if more {
			records.last().expect("positive page limit").revision
		} else {
			self.revision.max(after)
		};
		Ok(Page { next, more, records })
	}
}
