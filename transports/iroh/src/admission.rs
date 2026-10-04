//! Raw accept custody. The caller holds the mutex across generation checks
//! and queue mutations; async establishments carry only a generation token.

use super::{EV_ACCEPT, Readiness};
use std::collections::VecDeque;
use std::sync::Arc;

pub(crate) struct Queue<T> {
	enabled: bool,
	generation: u64,
	ready: VecDeque<T>,
	readiness: Arc<Readiness>,
}

impl<T> Queue<T> {
	pub(crate) fn new(readiness: Arc<Readiness>) -> Self {
		Self {
			enabled: true,
			generation: 1,
			ready: VecDeque::new(),
			readiness,
		}
	}

	pub(crate) fn generation(&self) -> Option<u64> {
		self.enabled.then_some(self.generation)
	}

	pub(crate) fn set_enabled(&mut self, enabled: bool) -> VecDeque<T> {
		self.enabled = enabled;
		if enabled {
			self.generation = self.generation.checked_add(1).expect("admission generation exhausted");
		}
		std::mem::take(&mut self.ready)
	}

	pub(crate) fn push(&mut self, generation: u64, value: T) -> bool {
		if self.generation() != Some(generation) || self.ready.len() == super::ACCEPT_QUEUE_BOUND {
			return false;
		}
		self.ready.push_back(value);
		self.readiness.signal(0, EV_ACCEPT);
		true
	}

	/// Keep level readiness live until the last raw connection is claimed.
	pub(crate) fn pop(&mut self) -> Option<T> {
		let value = self.ready.pop_front()?;
		if !self.ready.is_empty() {
			self.readiness.signal(0, EV_ACCEPT);
		}
		Some(value)
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn stopped_and_old_generation_completions_cannot_reenter() {
		let readiness = Readiness::new().unwrap();
		let mut queue = Queue::new(readiness.clone());
		let old = queue.generation().unwrap();
		for id in 0..super::super::ACCEPT_QUEUE_BOUND {
			assert!(queue.push(old, id));
		}
		assert!(!queue.push(old, 999));
		assert_eq!(queue.set_enabled(false).len(), super::super::ACCEPT_QUEUE_BOUND);
		assert_eq!(queue.generation(), None);
		assert!(!queue.push(old, 1000));
		queue.set_enabled(true);
		assert!(!queue.push(old, 1001));
		assert_eq!(queue.pop(), None);
		assert!(queue.push(queue.generation().unwrap(), 1002));
		assert_eq!(queue.pop(), Some(1002));
	}

	#[test]
	fn partial_claim_keeps_accept_readiness_live() {
		let readiness = Readiness::new().unwrap();
		let mut queue = Queue::new(readiness.clone());
		let generation = queue.generation().unwrap();
		for id in 0..super::super::ACCEPT_QUEUE_BOUND {
			assert!(queue.push(generation, id));
		}
		for id in 0..super::super::ACCEPT_QUEUE_BOUND {
			let mut events = [super::super::GlowcapIrohReadyEvent { subject: 0, events: 0 }];
			assert_eq!(readiness.drain(&mut events), 1);
			assert_eq!(events[0].events, EV_ACCEPT);
			assert_eq!(queue.pop(), Some(id));
		}
		assert_eq!(queue.pop(), None);
		let mut events = [super::super::GlowcapIrohReadyEvent { subject: 0, events: 0 }];
		assert_eq!(readiness.drain(&mut events), 0);
	}
}
