//! The trouble journal: the last failures that had no caller left to answer,
//! kept for an operator to read. A bounded ring, newest first, with a
//! repeated failure counted rather than repeated.
use alloc::{collections::VecDeque, string::String};

/// Entries the ring keeps.
pub const KEPT: usize = 50;
pub const MAX_SOURCE_BYTES: usize = 128;
pub const MAX_REASON_BYTES: usize = 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
	pub source: String,
	pub reason: String,
	pub count: u64,
}

#[derive(Default)]
pub struct Journal {
	entries: VecDeque<Entry>,
}

impl Journal {
	/// Record one failure. Answers whether the ring changed shape, which is
	/// when an operator watching the inventory should be told.
	pub fn note(&mut self, source: &str, reason: &str) -> bool {
		let source = bounded(source, MAX_SOURCE_BYTES);
		let reason = bounded(reason, MAX_REASON_BYTES);
		if let Some(newest) = self.entries.front_mut() {
			if newest.source == source && newest.reason == reason {
				newest.count += 1;
				return true;
			}
		}
		self.entries.push_front(Entry {
			source,
			reason,
			count: 1,
		});
		self.entries.truncate(KEPT);
		true
	}
	/// Newest first.
	pub fn rows(&self) -> impl Iterator<Item = &Entry> {
		self.entries.iter()
	}
	pub fn is_empty(&self) -> bool {
		self.entries.is_empty()
	}
	/// Forget everything; answers whether anything was there.
	pub fn clear(&mut self) -> bool {
		if self.entries.is_empty() {
			return false;
		}
		self.entries.clear();
		true
	}
}

/// `text` within `max` bytes: cut at a character boundary three bytes
/// short, then marked with an ellipsis.
fn bounded(text: &str, max: usize) -> String {
	if text.len() <= max {
		return text.into();
	}
	let mut end = max.saturating_sub(3);
	while end > 0 && !text.is_char_boundary(end) {
		end -= 1;
	}
	let mut cut = String::from(&text[..end]);
	cut.push('…');
	cut
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn a_repeated_failure_counts_and_the_ring_stays_bounded() {
		let mut journal = Journal::default();
		assert!(journal.note("notify", "closed"));
		assert!(journal.note("notify", "closed"));
		assert_eq!(journal.rows().next().unwrap().count, 2);
		for n in 0..60 {
			journal.note("other", &alloc::format!("{n}"));
		}
		assert_eq!(journal.rows().count(), KEPT);
		assert_eq!(journal.rows().next().unwrap().reason, "59");
		assert!(journal.clear());
		assert!(!journal.clear());
	}

	#[test]
	fn long_fields_are_cut_at_a_character_boundary() {
		let mut journal = Journal::default();
		let long: String = core::iter::repeat_n('é', 700).collect();
		journal.note(&long, &long);
		let row = journal.rows().next().unwrap();
		assert!(row.source.len() <= MAX_SOURCE_BYTES);
		assert!(row.source.ends_with('…'));
		assert!(row.reason.len() <= MAX_REASON_BYTES);
	}
}
