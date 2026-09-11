//! Capacity accounting for owned bounded fields, without serialization.
use super::{List, Nullable, Object, Text};
use alloc::{boxed::Box, vec::Vec};
pub(crate) trait HeapBytes {
	fn heap_bytes(&self) -> usize;
}
impl<const N: usize, const NONEMPTY: bool> HeapBytes for Text<N, NONEMPTY> {
	fn heap_bytes(&self) -> usize {
		self.text().heap_bytes()
	}
}
impl<T: HeapBytes, const N: usize> HeapBytes for List<T, N> {
	fn heap_bytes(&self) -> usize {
		self.0.heap_bytes()
	}
}
impl<T: HeapBytes> HeapBytes for Box<T> {
	fn heap_bytes(&self) -> usize {
		core::mem::size_of::<T>().saturating_add((**self).heap_bytes())
	}
}
impl<T: HeapBytes> HeapBytes for Option<T> {
	fn heap_bytes(&self) -> usize {
		self.as_ref().map_or(0, HeapBytes::heap_bytes)
	}
}
impl<T: HeapBytes> HeapBytes for Nullable<T> {
	fn heap_bytes(&self) -> usize {
		self.as_ref().map_or(0, HeapBytes::heap_bytes)
	}
}
impl<T: HeapBytes> HeapBytes for Object<T> {
	fn heap_bytes(&self) -> usize {
		self.0.heap_bytes()
	}
}
impl<T: HeapBytes> HeapBytes for Vec<T> {
	fn heap_bytes(&self) -> usize {
		self.iter().fold(
			self.capacity().saturating_mul(core::mem::size_of::<T>()),
			|sum, value| sum.saturating_add(value.heap_bytes()),
		)
	}
}
