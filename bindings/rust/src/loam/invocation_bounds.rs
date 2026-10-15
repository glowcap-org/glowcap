//! Scalar demand is derived by the shared owners, without walking a value tree.
use super::check;
use crate::{Result, sys::loam as ffi};

/// Every value node, including roots and struct values. Struct keys count
/// separately. Bytes sums all leaf occurrences, keys, tags, digits and errors.
/// Capabilities counts occurrences, including repeated identities.
#[derive(Clone, Copy, Default)]
pub struct ValueBounds {
	pub values: usize,
	pub struct_entries: usize,
	pub bytes: usize,
	pub capabilities: usize,
}
impl ValueBounds {
	/// Fixed Host reply allowance and retained Loam call contribution for
	/// forwarding. Other callback, input and admission demand remains separate.
	pub fn forwarding_size_bound(self) -> Result<(usize, usize)> {
		let (mut reply_bytes, mut call_bytes) = (0, 0);
		check(
			// SAFETY: this query takes no handle; `&self.raw()` is a temporary `GlowcapLoamValueBounds` that lives to
			// the end of this statement, and `reply_bytes` and `call_bytes` are local out-parameters the callee writes.
			unsafe { ffi::glowcap_loam_forwarding_size_bound(&self.raw(), &mut reply_bytes, &mut call_bytes) },
		)?;
		Ok((reply_bytes, call_bytes))
	}
	pub(super) fn raw(self) -> ffi::GlowcapLoamValueBounds {
		ffi::GlowcapLoamValueBounds {
			values: self.values,
			struct_entries: self.struct_entries,
			bytes: self.bytes,
			capabilities: self.capabilities,
		}
	}
}

pub struct InvocationBounds {
	/// Complete inbound vector, including mutate's sequence and method wrappers.
	pub arguments: ValueBounds,
	/// Must cover fresh and persisted receipt replies for this profile's lifetime.
	pub reply: ValueBounds,
	pub verb_bytes: usize,
	/// Application custody acquisitions, including repeated field accesses.
	pub held_occurrences: usize,
	pub receipt: bool,
	/// A local dependent target. External forwarding has separate demand.
	pub dependent: bool,
}
impl InvocationBounds {
	/// Conservative managed-content contribution to `Limits.call_bytes` for one
	/// attempt: retained input, private state, held custody, receipt encoding/replay,
	/// C arguments/policy copies and owning reply conversion, with physical block
	/// overhead. Add reference preparation, graph work and application allocations.
	/// Single-record content/reference edits, resource/control edits, sharing,
	/// observation and external forwarding are separate paths. Store staging,
	/// Capabilities operations, registration,
	/// settlement arenas, Rust buffers and Host network state have separate owners.
	/// This scalar query allocates nothing and admits no work.
	pub fn call_size_bound(self) -> Result<usize> {
		let raw = ffi::GlowcapLoamInvocationBounds {
			arguments: self.arguments.raw(),
			reply: self.reply.raw(),
			verb_bytes: self.verb_bytes,
			held_occurrences: self.held_occurrences,
			receipt: u32::from(self.receipt),
			dependent: u32::from(self.dependent),
		};
		let mut bytes = 0;
		check(
			// SAFETY: this query takes no handle; `&raw` is a local `GlowcapLoamInvocationBounds` borrowed for the call
			// and read only during it, and `bytes` is a local out-parameter the callee writes.
			unsafe { ffi::glowcap_loam_invocation_call_size_bound(&raw, &mut bytes) },
		)?;
		Ok(bytes)
	}
}
