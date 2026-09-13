use super::*;
use tokio::sync::Notify;
#[derive(Clone, Copy, Default)]
struct Usage {
	count: usize,
	bytes: usize,
	facts: usize,
	fact_bytes: usize,
}
struct State {
	usage: Cell<Usage>,
	/// Fired when a permit returns capacity, so a waiter for a full budget is
	/// woken by the release rather than by polling.
	released: Notify,
}
#[derive(Clone)]
pub(super) struct Budget(Rc<State>);
impl Budget {
	pub fn new() -> Self {
		Self(Rc::new(State {
			usage: Cell::new(Usage::default()),
			released: Notify::new(),
		}))
	}
	pub fn reserve(&self, bytes: usize, fact: bool) -> Option<Permit> {
		let mut usage = self.0.usage.get();
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
		self.0.usage.set(usage);
		Some(Permit {
			budget: self.clone(),
			bytes,
			fact,
		})
	}
	/// Resolves after the next permit returns capacity. Enable it before
	/// checking the budget so a release between the check and the wait is not
	/// lost.
	pub fn released(&self) -> tokio::sync::futures::Notified<'_> {
		self.0.released.notified()
	}
}
pub(super) struct Permit {
	budget: Budget,
	bytes: usize,
	fact: bool,
}
impl Drop for Permit {
	fn drop(&mut self) {
		let mut usage = self.budget.0.usage.get();
		usage.count -= 1;
		usage.bytes -= self.bytes;
		if self.fact {
			usage.facts -= 1;
			usage.fact_bytes -= self.bytes;
		}
		self.budget.0.usage.set(usage);
		self.budget.0.released.notify_waiters();
	}
}
