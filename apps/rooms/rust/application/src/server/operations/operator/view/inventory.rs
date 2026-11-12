//! A retained operator view owns admitted page chunks. Rendering flattens the
//! chunks without cloning rows. Failed admission leaves the old view intact.
use super::{Categories, Page, PageRows, Revision, Snapshot, rows::*};
use crate::{
	fields::{Nullable, Object, SafeInteger, footprint::HeapBytes},
	server::operations::operator::Category,
};
use alloc::{vec, vec::Vec};
use serde::{Serialize, Serializer, ser::SerializeSeq};

pub const MAX_RETAINED_BYTES: usize = 8 * 1024 * 1024;
const MAX_CHUNKS: usize = 256;
// Reserve accounting for worst-case chunk-vector capacities, independent of
// allocator growth. Each row chunk accounts for its own capacity and text.
const OVERHEAD: usize = core::mem::size_of::<Inventory>() + 7 * MAX_CHUNKS * core::mem::size_of::<Vec<()>>() + 128;
struct Chunks<T>(Vec<Rows<T>>);
impl<T: Serialize> Serialize for Chunks<T> {
	fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
		let mut rows = serializer.serialize_seq(Some(self.0.iter().map(|page| page.as_slice().len()).sum()))?;
		for page in &self.0 {
			for row in page.as_slice() {
				rows.serialize_element(row)?;
			}
		}
		rows.end()
	}
}
#[derive(Serialize)]
pub struct Inventory {
	pub revision: Revision,
	stewardships: Chunks<Stewardship>,
	links: Chunks<Link>,
	registrations: Chunks<Registration>,
	sessions: Chunks<Session>,
	rooms: Chunks<Room>,
	references: Chunks<Reference>,
	trouble: Chunks<Trouble>,
	pub next: Object<Categories<Nullable<SafeInteger>>>,
	pub totals: Object<Categories<SafeInteger>>,
	#[serde(skip)]
	bytes: usize,
	#[serde(skip)]
	chunks: usize,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Appended {
	Ready,
	Refresh,
}
impl Inventory {
	pub fn new(snapshot: Snapshot) -> Result<Self, &'static str> {
		macro_rules! first {
			($($name:ident),*) => { $(
				let count = snapshot.$name.as_slice().len() as u64;
				let total = snapshot.totals.$name.get();
				if count > total || snapshot.next.$name.as_ref().map(|value| value.get()) != (count < total).then_some(count) {
					return Err("Operator snapshot has inconsistent inventory cursors");
				}
			)* };
		}
		first!(stewardships, links, registrations, sessions, rooms, references, trouble);
		let bytes = OVERHEAD
			+ snapshot.stewardships.heap_bytes()
			+ snapshot.links.heap_bytes()
			+ snapshot.registrations.heap_bytes()
			+ snapshot.sessions.heap_bytes()
			+ snapshot.rooms.heap_bytes()
			+ snapshot.references.heap_bytes()
			+ snapshot.trouble.heap_bytes();
		if bytes > MAX_RETAINED_BYTES {
			return Err("Operator inventory exceeds its retained byte budget; narrow the search");
		}
		let Snapshot {
			revision,
			stewardships,
			links,
			registrations,
			sessions,
			rooms,
			references,
			trouble,
			next,
			totals,
		} = snapshot;
		Ok(Self {
			revision,
			stewardships: Chunks(vec![stewardships]),
			links: Chunks(vec![links]),
			registrations: Chunks(vec![registrations]),
			sessions: Chunks(vec![sessions]),
			rooms: Chunks(vec![rooms]),
			references: Chunks(vec![references]),
			trouble: Chunks(vec![trouble]),
			next,
			totals,
			bytes,
			chunks: 7,
		})
	}
	pub fn cursor(&self, category: Category) -> Option<u64> {
		self.next.get(category).as_ref().map(|value| value.get())
	}
	pub fn append(&mut self, category: Category, cursor: u64, page: Page) -> Result<Appended, &'static str> {
		if page.revision.get() != self.revision.get() {
			return Ok(Appended::Refresh);
		}
		if self.cursor(category) != Some(cursor) {
			return Err("Operator page cursor no longer names the current view");
		}
		let (actual, count, bytes) = match &page.rows {
			PageRows::Stewardships(rows) => (Category::Stewardships, rows.as_slice().len(), rows.heap_bytes()),
			PageRows::Links(rows) => (Category::Links, rows.as_slice().len(), rows.heap_bytes()),
			PageRows::Registrations(rows) => (Category::Registrations, rows.as_slice().len(), rows.heap_bytes()),
			PageRows::Sessions(rows) => (Category::Sessions, rows.as_slice().len(), rows.heap_bytes()),
			PageRows::Rooms(rows) => (Category::Rooms, rows.as_slice().len(), rows.heap_bytes()),
			PageRows::References(rows) => (Category::References, rows.as_slice().len(), rows.heap_bytes()),
			PageRows::Trouble(rows) => (Category::Trouble, rows.as_slice().len(), rows.heap_bytes()),
		};
		let end = cursor
			.checked_add(count as u64)
			.ok_or("Operator page cursor overflow")?;
		let total = page.total.get();
		if actual != category
			|| total != self.totals.get(category).get()
			|| end > total
			|| page.next.as_ref().map(|value| value.get()) != (end < total).then_some(end)
			|| (count == 0 && end < total)
		{
			return Err("Operator page does not continue the requested inventory");
		}
		let bytes = self
			.bytes
			.checked_add(bytes)
			.filter(|bytes| *bytes <= MAX_RETAINED_BYTES)
			.ok_or("Operator inventory exceeds its retained byte budget; narrow the search")?;
		if self.chunks >= MAX_CHUNKS {
			return Err("Operator inventory has reached its page limit; narrow the search");
		}
		match page.rows {
			PageRows::Stewardships(rows) => self.stewardships.0.push(rows),
			PageRows::Links(rows) => self.links.0.push(rows),
			PageRows::Registrations(rows) => self.registrations.0.push(rows),
			PageRows::Sessions(rows) => self.sessions.0.push(rows),
			PageRows::Rooms(rows) => self.rooms.0.push(rows),
			PageRows::References(rows) => self.references.0.push(rows),
			PageRows::Trouble(rows) => self.trouble.0.push(rows),
		}
		*self.next.0.get_mut(category) = page.next;
		self.bytes = bytes;
		self.chunks += 1;
		Ok(Appended::Ready)
	}
}

#[cfg(test)]
#[path = "inventory_tests.rs"]
mod tests;
