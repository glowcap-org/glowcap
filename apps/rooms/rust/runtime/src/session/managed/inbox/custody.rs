//! Shared retained callback count and bytes, with independent withdrawal slots.
use super::MAX_INBOXES;
use glowcap::Argument;
use rooms_application::room::inbox::queue;
use std::{cell::Cell, rc::Rc};
const MAX_VALUES: usize = 4096;
const MAX_DEPTH: usize = 32;
pub(super) struct Budget {
	messages: Cell<usize>,
	bytes: Cell<usize>,
	cleanup_messages: Cell<usize>,
	cleanup_bytes: Cell<usize>,
}
impl Default for Budget {
	fn default() -> Self {
		Self {
			messages: Cell::new(0),
			bytes: Cell::new(0),
			cleanup_messages: Cell::new(0),
			cleanup_bytes: Cell::new(0),
		}
	}
}
pub(super) struct Charge {
	budget: Rc<Budget>,
	bytes: usize,
	cleanup: bool,
}
impl Charge {
	pub(super) fn reserve(budget: &Rc<Budget>, bytes: usize, cleanup: bool) -> std::result::Result<Self, String> {
		let (messages, held_bytes, max_messages, max_bytes) = if cleanup {
			(
				&budget.cleanup_messages,
				&budget.cleanup_bytes,
				MAX_INBOXES * 2,
				MAX_INBOXES * 1024,
			)
		} else {
			(
				&budget.messages,
				&budget.bytes,
				queue::MAX_MESSAGES,
				queue::MAX_MESSAGE_BYTES,
			)
		};
		if messages.get() == max_messages || bytes > max_bytes.saturating_sub(held_bytes.get()) {
			return Err("Session callback backlog is full".into());
		}
		messages.set(messages.get() + 1);
		held_bytes.set(held_bytes.get() + bytes);
		Ok(Self {
			budget: budget.clone(),
			bytes,
			cleanup,
		})
	}
}
impl Drop for Charge {
	fn drop(&mut self) {
		let (messages, bytes) = if self.cleanup {
			(&self.budget.cleanup_messages, &self.budget.cleanup_bytes)
		} else {
			(&self.budget.messages, &self.budget.bytes)
		};
		messages.set(messages.get() - 1);
		bytes.set(bytes.get() - self.bytes);
	}
}
/// One borrowed walk bounds nodes and depth before copying a callback across
/// its asynchronous admission wait. Every payload is copied once. Vector slots
/// and owned strings are charged from the clone's lengths. Host guards retain
/// existing capability identity. Fixed queue/task/actor state is independently
/// bounded by MAX_INBOXES and QUEUED_PER_INBOX.
pub(super) fn demand(args: &[Argument]) -> std::result::Result<usize, String> {
	fn fields(values: &[Argument], depth: usize, nodes: &mut usize) -> Option<usize> {
		if depth > MAX_DEPTH || values.len() > MAX_VALUES.saturating_sub(*nodes) {
			return None;
		}
		*nodes += values.len();
		let mut bytes = values.len().checked_mul(size_of::<Argument>())?;
		for value in values {
			let owned = match value {
				Argument::Bytes(value) => value.len(),
				Argument::String(value)
				| Argument::Symbol(value)
				| Argument::Keyword(value)
				| Argument::Error(value) => value.len(),
				Argument::BigInteger { digits, .. } => digits.len(),
				Argument::Integers(words) => words.len().checked_mul(8)?,
				Argument::List(value) | Argument::Set(value) => fields(value, depth + 1, nodes)?,
				Argument::Tagged { tag, value } => tag.len().checked_add(fields(value, depth + 1, nodes)?)?,
				Argument::Struct(value) => {
					if depth == MAX_DEPTH || value.len() > MAX_VALUES.saturating_sub(*nodes) {
						return None;
					}
					let mut bytes = value.len().checked_mul(size_of::<(String, Argument)>())?;
					for (name, child) in value {
						bytes = bytes.checked_add(name.len())?.checked_add(
							fields(std::slice::from_ref(child), depth + 1, nodes)?.checked_sub(size_of::<Argument>())?,
						)?;
					}
					bytes
				}
				_ => 0,
			};
			bytes = bytes.checked_add(owned)?;
			if bytes > queue::MAX_MESSAGE_BYTES {
				return None;
			}
		}
		Some(bytes)
	}
	fields(args, 0, &mut 0)
		.and_then(|bytes| bytes.checked_add(size_of::<super::Pending>()))
		.filter(|bytes| *bytes <= queue::MAX_MESSAGE_BYTES)
		.ok_or_else(|| "Session callback input exceeds its count, depth or byte bound".into())
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn cleanup_custody_remains_independent_and_bounded_under_data_pressure() {
		let budget = Rc::new(Budget::default());
		let mut data = Vec::new();
		for _ in 0..queue::MAX_MESSAGES {
			data.push(Charge::reserve(&budget, 1, false).unwrap());
		}
		assert!(Charge::reserve(&budget, 1, false).is_err());
		let cleanup = Charge::reserve(&budget, 1, true).unwrap();
		assert_eq!(budget.cleanup_messages.get(), 1);
		assert!(Charge::reserve(&budget, MAX_INBOXES * 1024, true).is_err());
		drop(cleanup);
		assert_eq!(budget.cleanup_bytes.get(), 0);
		drop(data);
		assert_eq!(budget.messages.get(), 0);
		assert_eq!(budget.bytes.get(), 0);
	}
}
