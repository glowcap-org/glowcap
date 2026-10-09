//! Line metadata can grow on refile. Reserve its new aggregate cost before the
//! domain mutation, then transfer that reservation only after it commits.
use glowcap::{Result, loam};
use std::{cell::Cell, rc::Rc};

const MAX_BYTES: usize = 2 * 1024 * 1024;
#[derive(Clone)]
pub struct LineMemory(Rc<Allocation>);
struct Allocation {
	budget: Rc<Cell<usize>>,
	bytes: Cell<usize>,
	preparing: Cell<bool>,
	fixed: usize,
}
impl Drop for Allocation {
	fn drop(&mut self) {
		self.budget.set(self.budget.get() - self.bytes.get());
	}
}
impl LineMemory {
	pub(super) fn reserve(budget: Rc<Cell<usize>>, bytes: usize, fixed: usize) -> Result<Self> {
		let fixed = fixed.saturating_add(size_of::<Allocation>() + 2 * size_of::<usize>());
		let bytes = bytes.saturating_add(fixed);
		if bytes > MAX_BYTES.saturating_sub(budget.get()) {
			return Err(loam::refusal("received direct line capacity is exhausted"));
		}
		budget.set(budget.get() + bytes);
		Ok(Self(Rc::new(Allocation {
			budget,
			bytes: Cell::new(bytes),
			preparing: Cell::new(false),
			fixed,
		})))
	}
	/// The trusted consumer derives the full post-mutation metadata cost from
	/// Proposal's validated selection. Positive growth is charged before copying;
	/// a failed domain admission drops this guard and releases only that growth.
	pub fn prepare(&self, bytes: usize) -> Result<LineResize> {
		if self.0.preparing.get() {
			return Err(loam::refusal("line metadata resize is already prepared"));
		}
		let next = bytes.saturating_add(self.0.fixed);
		let growth = next.saturating_sub(self.0.bytes.get());
		if growth > MAX_BYTES.saturating_sub(self.0.budget.get()) {
			return Err(loam::refusal("received direct line capacity is exhausted"));
		}
		self.0.preparing.set(true);
		self.0.budget.set(self.0.budget.get() + growth);
		Ok(LineResize {
			memory: self.clone(),
			next,
			growth,
		})
	}
}
pub struct LineResize {
	memory: LineMemory,
	next: usize,
	growth: usize,
}
impl LineResize {
	pub fn commit(mut self) {
		let allocation = &self.memory.0;
		let shrink = allocation.bytes.get().saturating_sub(self.next);
		allocation.budget.set(allocation.budget.get() - shrink);
		allocation.bytes.set(self.next);
		self.growth = 0;
	}
}
impl Drop for LineResize {
	fn drop(&mut self) {
		let allocation = &self.memory.0;
		allocation.budget.set(allocation.budget.get() - self.growth);
		allocation.preparing.set(false);
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn aggregate_growth_is_reserved_before_commit_and_rollback_restores_capacity() {
		let budget = Rc::new(Cell::new(0));
		let first = LineMemory::reserve(budget.clone(), MAX_BYTES / 2, 0).unwrap();
		let second = LineMemory::reserve(budget.clone(), MAX_BYTES / 4, 0).unwrap();
		let before = budget.get();
		let pending = first.prepare(MAX_BYTES * 5 / 8).unwrap();
		assert!(
			second.prepare(MAX_BYTES / 2).is_err(),
			"another line cannot spend reserved growth"
		);
		drop(pending);
		assert_eq!(
			budget.get(),
			before,
			"refused domain mutation releases its tentative growth"
		);
		second.prepare(MAX_BYTES * 3 / 8).unwrap().commit();
		assert!(
			first.prepare(MAX_BYTES * 3 / 4).is_err(),
			"committed growth stays charged"
		);
		second.prepare(0).unwrap().commit();
		first.prepare(MAX_BYTES * 3 / 4).unwrap().commit();
		drop(first);
		drop(second);
		assert_eq!(budget.get(), 0, "actual retirement releases the final resized charge");
	}
}
