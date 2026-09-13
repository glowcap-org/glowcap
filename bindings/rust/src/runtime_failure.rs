//! Process-owned fallback for failures that outlive every Context recipient.

use crate::{Error, FailureEvent, FailureLayer, FailureScope};

pub(crate) use crate::abi_constants::{
	DEFAULT_FAILURE_CAPACITY as RUNTIME_FAILURE_CAP, DEFAULT_FAILURE_PAYLOAD_CAP as FAILURE_PAYLOAD_CAP,
};

pub(crate) struct RuntimeFailureJournal {
	failures: std::collections::VecDeque<FailureEvent>,
	next_sequence: u64,
}

impl RuntimeFailureJournal {
	pub(crate) fn new() -> Self {
		Self {
			failures: std::collections::VecDeque::with_capacity(RUNTIME_FAILURE_CAP),
			next_sequence: 1,
		}
	}

	pub(crate) fn record(&mut self, layer: FailureLayer, operation: &str, error: Error) {
		let mut dropped_before = 0;
		if self.failures.len() == RUNTIME_FAILURE_CAP {
			let dropped = self
				.failures
				.pop_front()
				.map_or(1, |event| event.dropped_before.saturating_add(1));
			if let Some(first) = self.failures.front_mut() {
				first.dropped_before = first.dropped_before.saturating_add(dropped);
			} else {
				dropped_before = dropped;
			}
		}
		let sequence = self.next_sequence;
		self.next_sequence = self.next_sequence.saturating_add(1);
		let primary_result = stable_failure_result(error.code);
		let primary_name = error.diagnostic_name();
		let primary_message = error.detail.as_deref().unwrap_or_default();
		let secondary_result = error
			.secondary
			.first()
			.map_or(0, |failure| stable_failure_result(failure.code));
		let secondary_count = error.secondary_count;
		let secondary_name = error.secondary.first().map_or("", Error::diagnostic_name);
		let secondary_message = error
			.secondary
			.first()
			.and_then(|failure| failure.detail.as_deref())
			.unwrap_or_default();
		let (
			[
				operation,
				primary_name,
				primary_message,
				secondary_name,
				secondary_message,
			],
			truncated_fields,
		) = bounded_failure_text([
			operation,
			primary_name,
			primary_message,
			secondary_name,
			secondary_message,
		]);
		self.failures.push_back(FailureEvent {
			sequence,
			dropped_before,
			layer,
			scope: FailureScope::Process,
			scope_id: 0,
			operation_id: 0,
			primary_result,
			secondary_result,
			secondary_count,
			truncated_fields,
			operation,
			primary_name,
			primary_message,
			secondary_name,
			secondary_message,
		});
		if sequence == u64::MAX {
			self.next_sequence = u64::MAX;
		}
	}

	pub(crate) fn claim(&mut self) -> Vec<FailureEvent> {
		self.failures.drain(..).collect()
	}
}

static RUNTIME_FAILURES: std::sync::OnceLock<std::sync::Mutex<RuntimeFailureJournal>> = std::sync::OnceLock::new();
#[cfg(all(test, feature = "async"))]
pub(crate) static RUNTIME_FAILURE_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn stable_failure_result(value: i32) -> i32 {
	if value == crate::sys::OK || (crate::sys::ERR_TIMEOUT..=crate::sys::ERR_NULL_POINTER).contains(&value) {
		value
	} else {
		crate::sys::ERR_INTERNAL
	}
}

fn bounded_failure_text(fields: [&str; 5]) -> ([String; 5], u32) {
	let mut remaining = FAILURE_PAYLOAD_CAP;
	let mut flags = 0;
	let retained = std::array::from_fn(|index| {
		let field = fields[index];
		let mut copied = field.len().min(remaining);
		while !field.is_char_boundary(copied) {
			copied -= 1;
		}
		remaining -= copied;
		if copied != field.len() {
			flags |= 1 << index;
		}
		field[..copied].to_owned()
	});
	(retained, flags)
}

pub(crate) fn record(layer: FailureLayer, operation: &str, error: Error) {
	let journal = RUNTIME_FAILURES.get_or_init(|| std::sync::Mutex::new(RuntimeFailureJournal::new()));
	let mut journal = journal.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
	journal.record(layer, operation, error);
}

pub(crate) fn claim() -> Vec<FailureEvent> {
	let Some(journal) = RUNTIME_FAILURES.get() else {
		return Vec::new();
	};
	let mut journal = journal.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
	journal.claim()
}
