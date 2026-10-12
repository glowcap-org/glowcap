//! Allocate reserved coordinates against held and pending custody in one walk.
use super::records;
use glowcap::{Result, loam};
use rooms_application::content::session::{
	custody::{self, Coordinate, FieldKey, Outcome},
	outgoing::Update,
};
use std::collections::BTreeSet;
use std::num::NonZeroU64;

fn slot(key: Coordinate) -> (usize, u64) {
	(key.role.index(), key.key.slot().get())
}
pub(super) struct Allocator {
	used: BTreeSet<(usize, u64)>,
	generation: NonZeroU64,
}
impl Allocator {
	pub(super) fn new(record: &records::Record, generation: NonZeroU64) -> Self {
		// One temporary set contains at most custody plus eight pending plans.
		// All files in the admission share it; no candidate rescans the graph.
		let used = record
			.custody
			.fields()
			.map(|field| field.coordinate())
			.chain(
				record
					.effects
					.as_slice()
					.iter()
					.filter(|effect| matches!(effect.outcome, Outcome::Unresolved))
					.filter_map(|effect| effect.outgoing.as_ref())
					.flat_map(Update::reserved),
			)
			.map(slot)
			.collect();
		Self { used, generation }
	}
	pub(super) fn allocate<K>(&mut self, role: custody::Role) -> Result<FieldKey<K>> {
		let index = custody::Role::ALL
			.iter()
			.position(|kind| *kind == role)
			.ok_or_else(|| loam::refusal("outgoing custody role is not declared"))?;
		let slot = (1..=custody::MAX_FIELDS_PER_ROLE as u64 + 1)
			.find(|slot| !self.used.contains(&(index, *slot)))
			.ok_or_else(|| loam::refusal("outgoing custody slots exhausted"))?;
		self.used.insert((index, slot));
		Ok(FieldKey::new(
			NonZeroU64::new(slot).ok_or_else(|| loam::refusal("outgoing custody slots exhausted"))?,
			self.generation,
		))
	}
}
