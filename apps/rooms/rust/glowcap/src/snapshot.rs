//! The snapshot contract's nested list view over a delivered CapTP argument.
use crate::Value;
use glowcap::Argument;
use rooms_application::session::snapshot::SnapshotArgument;

impl SnapshotArgument for Value<'_> {
	type Item<'a>
		= Value<'a>
	where
		Self: 'a;
	fn list(&self) -> Option<impl ExactSizeIterator<Item = Value<'_>>> {
		match self.0 {
			Argument::List(values) => Some(values.iter().map(Value)),
			_ => None,
		}
	}
}
