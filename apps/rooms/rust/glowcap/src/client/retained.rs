//! Account owned request storage without copying or encoding it again.
use glowcap::Argument;

pub(super) fn arguments(values: &[Argument]) -> usize {
	values.iter().map(heap).fold(0, usize::saturating_add)
}
pub(super) fn vector(values: &Vec<Argument>) -> usize {
	(values.capacity() * size_of::<Argument>()).saturating_add(arguments(values))
}
fn heap(value: &Argument) -> usize {
	match value {
		Argument::Bytes(bytes) => bytes.capacity(),
		Argument::String(text) | Argument::Symbol(text) | Argument::Error(text) | Argument::Keyword(text) => {
			text.capacity()
		}
		Argument::BigInteger { digits, .. } => digits.capacity(),
		Argument::List(values) | Argument::Set(values) => vector(values),
		Argument::Tagged { tag, value } => tag.capacity().saturating_add(vector(value)),
		Argument::Struct(values) => values.iter().fold(
			values.capacity() * size_of::<(String, Argument)>(),
			|total, (key, value)| total.saturating_add(key.capacity()).saturating_add(heap(value)),
		),
		Argument::Integer(_) | Argument::Float(_) | Argument::Boolean(_) | Argument::Void | Argument::Reference(_) => 0,
	}
}
