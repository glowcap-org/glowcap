//! Native CapTP argument construction for the shared Rooms snapshot contract.
use crate::Value;
use glowcap::Argument;
use rooms_application::session::snapshot::{BuildArguments, SnapshotArgument};

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
pub struct Arguments;
impl BuildArguments for Arguments {
	type Value = Argument;
	fn text(value: String) -> Argument {
		Argument::String(value)
	}
	fn integer(value: u64) -> Argument {
		Argument::Integer(value as i64)
	}
	fn null() -> Argument {
		Argument::Void
	}
	fn list(values: Vec<Argument>) -> Argument {
		Argument::List(values)
	}
}

impl rooms_application::server::rooms::wire::DataEncoder for Arguments {
	type Value = Argument;
	fn text(&mut self, value: String) -> Argument {
		Argument::String(value)
	}
	fn integer(&mut self, value: u64) -> Argument {
		Argument::Integer(value as i64)
	}
	fn boolean(&mut self, value: bool) -> Argument {
		Argument::Boolean(value)
	}
}
