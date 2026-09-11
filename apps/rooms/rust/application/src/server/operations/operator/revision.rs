//! The operator's change bus: one monotonic revision every inventory
//! answer carries, and the watchers told when it moves. A held notice
//! coalesces a sweep's hundred changes into one word, while the revision
//! itself still advances under every change, because it is the inventory's
//! authority and cannot be batched.
use alloc::{collections::BTreeMap, format, string::String};

/// Watchers one operator keeps.
pub const MAX_WATCHERS: usize = 256;

pub struct Revision<C, R> {
	current: u64,
	watchers: BTreeMap<C, R>,
	holding: u32,
	missed: bool,
}

impl<C, R> Default for Revision<C, R> {
	fn default() -> Self {
		Self {
			current: 0,
			watchers: BTreeMap::new(),
			holding: 0,
			missed: false,
		}
	}
}

/// What a change asks the adapter to do: tell every watcher the revision.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Announce(pub u64);

impl<C: Copy + Ord, R: Clone> Revision<C, R> {
	pub fn current(&self) -> u64 {
		self.current
	}
	/// Something an inventory reads changed. Answers the revision to
	/// announce, unless a hold is coalescing announcements.
	pub fn note(&mut self) -> Option<Announce> {
		self.current += 1;
		if self.holding > 0 {
			self.missed = true;
			return None;
		}
		Some(Announce(self.current))
	}
	/// Coalesce the announcements of the changes until the matching release.
	pub fn hold(&mut self) {
		self.holding += 1;
	}
	/// Release one hold; the last one answers the announcement it withheld.
	pub fn release_hold(&mut self) -> Option<Announce> {
		self.holding = self.holding.saturating_sub(1);
		if self.holding == 0 && core::mem::take(&mut self.missed) {
			return Some(Announce(self.current));
		}
		None
	}
	/// Admit `observer` for `connection`, replacing the one it held. Answers
	/// the replaced observer to give back.
	pub fn watch(&mut self, connection: C, observer: R) -> Result<Option<R>, String> {
		if !self.watchers.contains_key(&connection) && self.watchers.len() >= MAX_WATCHERS {
			return Err(format!("this Rooms operator already has {MAX_WATCHERS} watchers"));
		}
		Ok(self.watchers.insert(connection, observer))
	}
	pub fn unwatch(&mut self, connection: C) -> Option<R> {
		self.watchers.remove(&connection)
	}
	pub fn watchers(&self) -> impl Iterator<Item = (C, &R)> {
		self.watchers
			.iter()
			.map(|(connection, observer)| (*connection, observer))
	}
	pub fn is_watching(&self, connection: C) -> bool {
		self.watchers.contains_key(&connection)
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn holds_coalesce_announcements_while_the_revision_advances() {
		let mut revision: Revision<u16, &str> = Revision::default();
		assert_eq!(revision.note(), Some(Announce(1)));
		revision.hold();
		assert_eq!(revision.note(), None);
		assert_eq!(revision.note(), None);
		assert_eq!(revision.current(), 3);
		assert_eq!(revision.release_hold(), Some(Announce(3)));
		assert_eq!(revision.release_hold(), None);
		assert_eq!(revision.watch(1, "a").unwrap(), None);
		assert_eq!(revision.watch(1, "b").unwrap(), Some("a"));
		for n in 2..=MAX_WATCHERS as u16 {
			revision.watch(n, "w").unwrap();
		}
		assert!(revision.watch(0, "late").is_err());
		assert_eq!(revision.unwatch(1), Some("b"));
	}
}
