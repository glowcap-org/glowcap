//! Ordered event admission and bounded initial custody. Adapters supply owned
//! notices and their retained size; eviction drops their capability guards.
use alloc::{collections::VecDeque, string::String};

pub const MAX_EVENTS: usize = 256;
pub const MAX_BYTES: usize = 4 * 1024 * 1024;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Admission {
	Accept,
	Duplicate,
	Gap,
}
pub struct Events<T> {
	source: Option<String>,
	sequence: u64,
	pending: VecDeque<(T, usize)>,
	bytes: usize,
}
impl<T> Default for Events<T> {
	fn default() -> Self {
		Self {
			source: None,
			sequence: 0,
			pending: VecDeque::new(),
			bytes: 0,
		}
	}
}
impl<T> Events<T> {
	pub fn admit(&mut self, source: &str, sequence: u64) -> Admission {
		let same = self.source.as_deref() == Some(source);
		if same && sequence <= self.sequence {
			return Admission::Duplicate;
		}
		let expected = if same { self.sequence.checked_add(1) } else { Some(1) };
		if !same {
			self.source = Some(source.into());
		}
		self.sequence = sequence;
		if expected == Some(sequence) {
			Admission::Accept
		} else {
			Admission::Gap
		}
	}
	/// Keep the newest bounded suffix. Returns whether any notice was lost.
	pub fn push(&mut self, notice: T, bytes: usize) -> bool {
		if bytes > MAX_BYTES {
			return true;
		}
		let mut lost = false;
		while self.pending.len() >= MAX_EVENTS || bytes > MAX_BYTES - self.bytes {
			self.pop();
			lost = true;
		}
		self.pending.push_back((notice, bytes));
		self.bytes += bytes;
		lost
	}
	pub fn pop(&mut self) -> Option<T> {
		self.pending.pop_front().map(|(notice, bytes)| {
			self.bytes -= bytes;
			notice
		})
	}
	pub fn clear(&mut self) {
		self.pending.clear();
		self.bytes = 0;
	}
}
