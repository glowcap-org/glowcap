//! Capacity accounting for owned bounded fields, without serialization.
use super::{List, Nullable, Object, Text};
use alloc::{boxed::Box, vec::Vec};
pub(crate) trait HeapBytes {
	fn heap_bytes(&self) -> usize;
}
/// Values that own no heap.
macro_rules! scalar {
	($($kind:ty),* $(,)?) => { $(impl $crate::fields::footprint::HeapBytes for $kind {
		fn heap_bytes(&self) -> usize { 0 }
	})* };
}
/// The heap a struct's fields own: those named before the `;` are summed and
/// those after it own none. Naming every field makes a new one require an
/// accounting decision.
macro_rules! graph {
	($kind:ident { $($owned:ident),* $(,)? $(; $($scalar:ident),* $(,)?)? }) => {
		impl $crate::fields::footprint::HeapBytes for $kind {
			fn heap_bytes(&self) -> usize {
				let Self { $($owned,)* $($($scalar: _,)*)? } = self;
				0usize $(.saturating_add($crate::fields::footprint::HeapBytes::heap_bytes($owned)))*
			}
		}
	};
}
pub(crate) use {graph, scalar};
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
