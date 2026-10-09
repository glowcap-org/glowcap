//! Complete shared-call and encoded-row allowances for this session trace.
use super::content;
use glowcap::loam::{Limits, ValueBounds};

pub fn limits() -> Limits {
	// Three effect fields accompany this trace's custody inventory. Replacement
	// declares saves for custody; effects reuse those exact prepared targets.
	let fields = content::FIELDS + 3;
	let saves = content::FIELDS;
	limits_for(
		fields,
		saves,
		ValueBounds {
			values: 1,
			capabilities: 1,
			..ValueBounds::default()
		},
	)
}

pub(crate) fn limits_for(fields: usize, saves: usize, reply: ValueBounds) -> Limits {
	limits_for_input(
		fields,
		saves,
		ValueBounds {
			values: 4,
			bytes: "write".len(),
			capabilities: 1,
			..ValueBounds::default()
		},
		reply,
	)
}
pub(crate) fn limits_for_input(fields: usize, saves: usize, arguments: ValueBounds, reply: ValueBounds) -> Limits {
	rooms_runtime::session::managed::storage_limits(fields, fields, saves, "mutation-sequence".len(), arguments, reply)
		.unwrap()
}
