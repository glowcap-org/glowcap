//! One fixed-size row per retained key. Fully refilled rows may retire without
//! changing allowance. Maintenance visits at most `MAINTENANCE_ROWS` rows per
//! step.
use super::{Bucket, CLASS_COUNT, CLASSES, Class, CleanupReserve, Profile, Refusal};
use alloc::collections::BTreeMap;
use core::ops::Bound::{Excluded, Unbounded};

/// Calls between maintenance steps while the registry is below capacity.
const MAINTENANCE_PERIOD: u64 = 64;
/// Rows one maintenance step visits.
const MAINTENANCE_ROWS: usize = 8;

#[derive(Clone, Copy)]
pub struct Charge<K> {
	pub key: K,
	pub class: Class,
	pub amount: u32,
}
#[derive(Clone, Copy, Debug, Default)]
pub struct Statistics {
	pub admitted: u64,
	pub refused: u64,
	pub coalesced: u64,
	pub capacity: u64,
	pub classes: [ClassStatistics; CLASS_COUNT],
}
#[derive(Clone, Copy, Debug, Default)]
pub struct ClassStatistics {
	pub admitted: u64,
	pub refused: u64,
	pub coalesced: u64,
}
type Row = [Bucket; CLASS_COUNT];
/// Rates remain fixed for the registry's lifetime. A typed owner may give its
/// aggregate pool more allowance than individual subjects without creating
/// separate debit owners or making refusal consume a sibling allowance.
pub trait Policy<K> {
	fn rate(&self, key: K, class: Class) -> super::Rate;
}
impl<K> Policy<K> for Profile {
	fn rate(&self, _: K, class: Class) -> super::Rate {
		self.rate(class)
	}
}
/// Retained admission cost: at most `limit` BTreeMap entries, each containing
/// one Copy key and CLASS_COUNT two-word buckets, plus bounded tree spines.
/// Keys cannot own heap storage. Lookup, debit and maintenance allocate nothing.
/// The tree allocates only when a newly retained key needs a node.
pub struct Registry<K: Copy + Ord, P: Policy<K> = Profile> {
	rows: BTreeMap<K, Row>,
	profile: P,
	limit: usize,
	cursor: Option<K>,
	calls: u64,
	statistics: Statistics,
}
impl<K: Copy + Ord, P: Policy<K>> Registry<K, P> {
	pub fn new(profile: P, limit: usize) -> Self {
		assert!(limit != 0);
		Self {
			rows: BTreeMap::new(),
			profile,
			limit,
			cursor: None,
			calls: 0,
			statistics: Statistics::default(),
		}
	}
	pub fn len(&self) -> usize {
		self.rows.len()
	}
	pub fn is_empty(&self) -> bool {
		self.rows.is_empty()
	}
	pub const fn statistics(&self) -> Statistics {
		self.statistics
	}
	pub fn coalesced(&mut self, class: Class) {
		self.statistics.coalesced = self.statistics.coalesced.saturating_add(1);
		let count = &mut self.statistics.classes[class as usize].coalesced;
		*count = count.saturating_add(1);
	}
	pub fn maintain(&mut self, now: u64) {
		self.maintain_excluding(now, &[]);
	}
	fn maintain_excluding(&mut self, now: u64, active: &[Charge<K>]) {
		for _ in 0..MAINTENANCE_ROWS {
			let next = match self.cursor {
				Some(key) => self.rows.range((Excluded(key), Unbounded)).next(),
				None => self.rows.first_key_value(),
			};
			let Some((&key, row)) = next else {
				self.cursor = None;
				break;
			};
			let restored = CLASSES
				.iter()
				.all(|&class| row[class as usize].restored(self.profile.rate(key, class), now));
			self.cursor = Some(key);
			if restored && !active.iter().any(|charge| charge.key == key) {
				self.rows.remove(&key);
			}
		}
	}
	pub fn admit(&mut self, charges: &[Charge<K>], now: u64) -> Result<(), Refusal> {
		self.admit_with_reserve(charges, now, None)
	}
	/// The caller has already validated the exact cleanup operation and authority.
	/// A reserve pays only when rows cannot be retained. Existing rows still spend
	/// their subject allowance. Missing rows never enter the full table.
	pub fn admit_cleanup(
		&mut self,
		charges: &[Charge<K>],
		now: u64,
		reserve: &mut CleanupReserve,
	) -> Result<(), Refusal> {
		assert!(charges.iter().all(|charge| charge.class == Class::Cleanup));
		self.admit_with_reserve(charges, now, Some(reserve))
	}
	fn admit_with_reserve(
		&mut self,
		charges: &[Charge<K>],
		now: u64,
		reserve: Option<&mut CleanupReserve>,
	) -> Result<(), Refusal> {
		let mut result = self.check(charges, now);
		let mut reserved = false;
		if let (Err(Refusal::Capacity), Some(reserve)) = (result, reserve) {
			// An ancestry chain charges the same work at each authority boundary.
			// The reserve pays once for the largest requested dimension.
			let amount = charges
				.iter()
				.map(|charge| {
					charges
						.iter()
						.filter(|other| same_dimension(other, charge))
						.fold(0u32, |sum, other| sum.saturating_add(other.amount))
				})
				.max()
				.unwrap_or(0);
			result = reserve.admit(amount, now);
			reserved = result.is_ok();
		}
		match result {
			Ok(()) => {
				for charge in charges {
					let row = if reserved {
						let Some(row) = self.rows.get_mut(&charge.key) else {
							continue;
						};
						row
					} else {
						self.rows.entry(charge.key).or_insert([Bucket::default(); CLASS_COUNT])
					};
					row[charge.class as usize].debit(self.profile.rate(charge.key, charge.class), charge.amount, now);
				}
				self.statistics.admitted = self.statistics.admitted.saturating_add(1);
				for (index, charge) in charges.iter().enumerate() {
					if charges[..index].iter().any(|prior| prior.class == charge.class) {
						continue;
					}
					let counter = &mut self.statistics.classes[charge.class as usize];
					counter.admitted = counter.admitted.saturating_add(1);
				}
			}
			Err(error) => {
				self.statistics.refused = self.statistics.refused.saturating_add(1);
				if let Refusal::Throttled { class, .. } | Refusal::TooLarge { class } = error {
					let counter = &mut self.statistics.classes[class as usize];
					counter.refused = counter.refused.saturating_add(1);
				}
			}
		}
		result
	}
	fn check(&mut self, charges: &[Charge<K>], now: u64) -> Result<(), Refusal> {
		self.calls = self.calls.wrapping_add(1);
		if self.calls.is_multiple_of(MAINTENANCE_PERIOD) || self.at_capacity(charges) {
			self.maintain_excluding(now, charges);
		}
		let mut refusal = None;
		for (index, charge) in charges.iter().enumerate() {
			// Check each dimension once against the entire requested debit.
			if charges[..index].iter().any(|prior| same_dimension(prior, charge)) {
				continue;
			}
			let amount = charges
				.iter()
				.filter(|c| same_dimension(c, charge))
				.try_fold(0u32, |sum, c| sum.checked_add(c.amount))
				.ok_or(Refusal::TooLarge { class: charge.class })?;
			let bucket = self
				.rows
				.get(&charge.key)
				.map_or(Bucket::default(), |row| row[charge.class as usize]);
			if let Err(error) = bucket.check(self.profile.rate(charge.key, charge.class), amount, now, charge.class) {
				match (refusal, error) {
					(Some(Refusal::Throttled { retry_ms: prior, .. }), Refusal::Throttled { retry_ms, .. })
						if prior >= retry_ms => {}
					(_, Refusal::TooLarge { .. }) => return Err(error),
					_ => refusal = Some(error),
				}
			}
		}
		if let Some(refusal) = refusal {
			return Err(refusal);
		}
		if self.at_capacity(charges) {
			self.statistics.capacity = self.statistics.capacity.saturating_add(1);
			return Err(Refusal::Capacity);
		}
		Ok(())
	}
	fn at_capacity(&self, charges: &[Charge<K>]) -> bool {
		let missing = charges
			.iter()
			.enumerate()
			.filter(|(index, charge)| {
				!self.rows.contains_key(&charge.key) && !charges[..*index].iter().any(|prior| prior.key == charge.key)
			})
			.count();
		missing > self.limit - self.rows.len()
	}
}

fn same_dimension<K: PartialEq>(left: &Charge<K>, right: &Charge<K>) -> bool {
	left.key == right.key && left.class == right.class
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn maintenance_preserves_the_current_requests_restored_row() {
		let mut registry = Registry::new(Profile::default(), 8);
		let active = [Charge {
			key: 1u64,
			class: Class::Message,
			amount: 1,
		}];
		registry.admit(&active, 0).unwrap();
		registry
			.admit(
				&[Charge {
					key: 2,
					class: Class::Message,
					amount: 1,
				}],
				0,
			)
			.unwrap();
		registry.maintain_excluding(60_000, &active);
		assert!(
			registry.rows.contains_key(&1),
			"maintenance retired the current request's row"
		);
		assert!(!registry.rows.contains_key(&2), "idle restored row was not reclaimed");
	}
}
