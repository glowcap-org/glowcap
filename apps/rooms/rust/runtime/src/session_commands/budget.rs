use super::*;
#[derive(Clone, Copy, Default)]
struct Usage {
	count: usize,
	bytes: usize,
	facts: usize,
	fact_bytes: usize,
}
#[derive(Clone)]
pub(super) struct Budget(Rc<Cell<Usage>>);
impl Budget {
	pub fn new() -> Self {
		Self(Rc::new(Cell::new(Usage::default())))
	}
	pub fn reserve(&self, bytes: usize, fact: bool) -> Option<Permit> {
		let mut usage = self.0.get();
		if usage.count >= MAX_PENDING
			|| bytes > MAX_RETAINED_BYTES.saturating_sub(usage.bytes)
			|| (fact && (usage.facts >= MAX_PENDING_FACTS || bytes > MAX_FACT_BYTES.saturating_sub(usage.fact_bytes)))
		{
			return None;
		}
		usage.count += 1;
		usage.bytes += bytes;
		if fact {
			usage.facts += 1;
			usage.fact_bytes += bytes;
		}
		self.0.set(usage);
		Some(Permit {
			budget: self.clone(),
			bytes,
			fact,
		})
	}
}
pub(super) struct Permit {
	budget: Budget,
	bytes: usize,
	fact: bool,
}
impl Drop for Permit {
	fn drop(&mut self) {
		let mut usage = self.budget.0.get();
		usage.count -= 1;
		usage.bytes -= self.bytes;
		if self.fact {
			usage.facts -= 1;
			usage.fact_bytes -= self.bytes;
		}
		self.budget.0.set(usage);
	}
}
