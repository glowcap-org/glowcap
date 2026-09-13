//! Directory-wide observers of live registration and room state, one per
//! connection. Every event walks this table, so a connection that could add
//! rows without limit would make each change do its work again per row;
//! watching again replaces, as re-claiming a seat replaces a membership.
use super::{MAX_WATCHERS, Refusal, discovery::Shape};
use alloc::{collections::BTreeMap, format};

pub(super) struct Watchers<C, R> {
	rows: BTreeMap<C, (R, Shape)>,
}

impl<C, R> Default for Watchers<C, R> {
	fn default() -> Self {
		Self { rows: BTreeMap::new() }
	}
}

impl<C: Copy + Ord, R> Watchers<C, R> {
	/// Admit `observer` for `connection`, answering the observer it replaced.
	pub fn push(&mut self, connection: C, observer: R, shape: Shape) -> Result<Option<R>, Refusal> {
		if !self.rows.contains_key(&connection) && self.rows.len() >= MAX_WATCHERS {
			return Err(Refusal::plain(format!(
				"this directory already has {MAX_WATCHERS} watchers"
			)));
		}
		Ok(self
			.rows
			.insert(connection, (observer, shape))
			.map(|(replaced, _)| replaced))
	}
	pub fn remove(&mut self, connection: C) -> Option<R> {
		self.rows.remove(&connection).map(|(observer, _)| observer)
	}
	pub fn iter(&self) -> impl Iterator<Item = (C, &R, Shape)> {
		self.rows
			.iter()
			.map(|(connection, (observer, shape))| (*connection, observer, *shape))
	}
}
