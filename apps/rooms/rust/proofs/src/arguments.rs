use rooms_application::room::ArgumentView;
use rooms_application::room::attachment::AttachmentArgument;
use serde_json::Value;
use std::{cell::Cell, rc::Rc};

// Test-only decoded values. Production adapters implement ArgumentView over
// their binding's arguments and retain its existing capability guards.
pub(super) enum Arg {
	Boolean(bool),
	Null,
	Text(String),
	Integer(i128),
	Float(f64),
	Bytes(Vec<u8>),
	Other,
	Capability(Rc<Cell<usize>>),
	List(Vec<Arg>),
}
impl ArgumentView for &Arg {
	fn boolean(&self) -> Option<bool> {
		Arg::boolean(self)
	}
	fn is_null(&self) -> bool {
		Arg::is_null(self)
	}
	fn text(&self) -> Option<&str> {
		Arg::text(self)
	}
	fn integer(&self) -> Option<i128> {
		Arg::integer(self)
	}
	fn float(&self) -> Option<f64> {
		Arg::float(self)
	}
	fn contains_capability(&self) -> bool {
		Arg::contains_capability(self)
	}
}
impl rooms_application::directory::Argument for &Arg {
	fn list_len(&self) -> Option<usize> {
		if let Arg::List(values) = self {
			Some(values.len())
		} else {
			None
		}
	}
	fn at(&self, index: usize) -> Option<Self> {
		if let Arg::List(values) = self {
			values.get(index)
		} else {
			None
		}
	}
}

impl rooms_application::files::FileArgument for Arg {
	fn bytes(&self) -> Option<&[u8]> {
		if let Self::Bytes(bytes) = self {
			Some(bytes)
		} else {
			None
		}
	}
	fn natural(&self) -> Option<u64> {
		self.integer()
			.filter(|&n| n >= 0)
			.map(|n| u64::try_from(n).unwrap_or(u64::MAX))
	}
}

impl AttachmentArgument for Arg {
	type Capability = Rc<Cell<usize>>;
	fn capability(&self) -> Option<&Rc<Cell<usize>>> {
		if let Self::Capability(capability) = self {
			Some(capability)
		} else {
			None
		}
	}
}

impl Drop for Arg {
	fn drop(&mut self) {
		if let Self::Capability(drops) = self {
			drops.set(drops.get() + 1);
		}
	}
}

impl ArgumentView for Arg {
	fn boolean(&self) -> Option<bool> {
		if let Self::Boolean(value) = self {
			Some(*value)
		} else {
			None
		}
	}
	fn is_null(&self) -> bool {
		matches!(self, Self::Null)
	}
	fn text(&self) -> Option<&str> {
		match self {
			Self::Text(text) => Some(text),
			_ => None,
		}
	}
	fn integer(&self) -> Option<i128> {
		match self {
			Self::Integer(value) => Some(*value),
			_ => None,
		}
	}
	fn contains_capability(&self) -> bool {
		match self {
			Self::Capability(_) => true,
			Self::List(values) => values.iter().any(ArgumentView::contains_capability),
			_ => false,
		}
	}
	fn float(&self) -> Option<f64> {
		match self {
			Self::Float(value) => Some(*value),
			_ => None,
		}
	}
}

pub(super) fn text(value: &str) -> Arg {
	Arg::Text(value.into())
}

pub(super) fn from_fixture(value: &Value) -> Arg {
	if value.is_null() {
		Arg::Null
	} else if let Some(value) = value.as_bool() {
		Arg::Boolean(value)
	} else if let Some(text) = value.as_str() {
		Arg::Text(text.into())
	} else if let Some(integer) = value.get("integer").and_then(Value::as_str) {
		Arg::Integer(integer.parse().unwrap())
	} else if let Some(number) = value.as_f64() {
		Arg::Float(number)
	} else if value.get("capability").and_then(Value::as_bool) == Some(true) {
		Arg::Capability(Rc::new(Cell::new(0)))
	} else if let Some(values) = value.as_array() {
		Arg::List(values.iter().map(from_fixture).collect())
	} else {
		Arg::Other
	}
}

impl rooms_application::files::FileArgument for &Arg {
	fn bytes(&self) -> Option<&[u8]> {
		rooms_application::files::FileArgument::bytes(*self)
	}
	fn natural(&self) -> Option<u64> {
		rooms_application::files::FileArgument::natural(*self)
	}
}

impl AttachmentArgument for &Arg {
	type Capability = Rc<Cell<usize>>;
	fn capability(&self) -> Option<&Self::Capability> {
		Arg::capability(self)
	}
}
