//! The one argument value tests decode wire shapes into: text, naturals,
//! booleans, bytes, null and lists, read through the same views a binding supplies.
use super::{ArgumentView, ListArgument};
use crate::files::FileArgument;
use alloc::{string::String, vec::Vec};

#[derive(Clone, Debug, PartialEq)]
pub(crate) enum Value {
	Text(String),
	Integer(u64),
	Boolean(bool),
	Bytes(Vec<u8>),
	Null,
	List(Vec<Value>),
}
impl ArgumentView for Value {
	fn boolean(&self) -> Option<bool> {
		match self {
			Self::Boolean(value) => Some(*value),
			_ => None,
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
			Self::Integer(n) => Some(i128::from(*n)),
			_ => None,
		}
	}
	fn float(&self) -> Option<f64> {
		None
	}
	fn contains_capability(&self) -> bool {
		false
	}
}
impl ArgumentView for &Value {
	fn boolean(&self) -> Option<bool> {
		(**self).boolean()
	}
	fn is_null(&self) -> bool {
		(**self).is_null()
	}
	fn text(&self) -> Option<&str> {
		(**self).text()
	}
	fn integer(&self) -> Option<i128> {
		(**self).integer()
	}
	fn float(&self) -> Option<f64> {
		(**self).float()
	}
	fn contains_capability(&self) -> bool {
		(**self).contains_capability()
	}
}
impl ListArgument for Value {
	fn list_len(&self) -> Option<usize> {
		match self {
			Self::List(items) => Some(items.len()),
			_ => None,
		}
	}
	fn at(&self, index: usize) -> Option<Self> {
		match self {
			Self::List(items) => items.get(index).cloned(),
			_ => None,
		}
	}
}
impl ListArgument for &Value {
	fn list_len(&self) -> Option<usize> {
		(**self).list_len()
	}
	fn at(&self, index: usize) -> Option<Self> {
		match self {
			Value::List(items) => items.get(index),
			_ => None,
		}
	}
}
impl FileArgument for Value {
	fn bytes(&self) -> Option<&[u8]> {
		match self {
			Self::Bytes(bytes) => Some(bytes),
			_ => None,
		}
	}
	fn natural(&self) -> Option<u64> {
		match self {
			Self::Integer(n) => Some(*n),
			_ => None,
		}
	}
}
