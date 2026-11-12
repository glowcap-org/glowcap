//! Store and attachment quotas, their defaults, and the C ABI projection.
use crate::sys::loam as ffi;

#[derive(Clone, Copy)]
pub struct Limits {
	pub resident_bytes: usize,
	pub staging_bytes: usize,
	pub cache_slots: usize,
	/// Records a walk may read before it needs them. Each holds a cache slot
	/// until demand pins it, so `cache_slots` covers demand plus this depth.
	pub read_ahead: usize,
	pub max_leases: usize,
	pub max_changes: usize,
	/// Live attachment endpoints, independent of Store retention tokens.
	pub max_references: usize,
	pub max_operations: usize,
	/// One retained call's arena blocks, including graph snapshots,
	/// block headers, alignment and spare capacity. Backing grows as needed.
	pub call_bytes: usize,
	/// Whole-call ceiling reservations for admitted calls in this attachment.
	pub pending_bytes: usize,
	/// Whole-call ceiling reservations per attachment and ingress, after dispatch.
	pub ingress_bytes: usize,
	/// Pinned managed records per operation, excluding temporary directory and
	/// descriptor leases. Store max_leases must leave room for both.
	pub record_capacity: usize,
	/// Live save proofs, including completed proofs retained through outcome.
	pub max_reference_saves: usize,
	/// Maximum encoded physical record, including its envelope and checksum.
	pub record_bytes: usize,
	/// Live Store roots, including restored recipes held through settlement.
	pub max_retentions: usize,
	/// Live receipt continuations, independent of pending call admission.
	pub max_continuations: usize,
	/// Complete immutable intent and exact-target custody per continuation.
	pub continuation_bytes: usize,
	pub max_continuation_targets: usize,
	/// Fixed owning reply allowance for each forwarded target execution.
	pub forward_reply_bytes: usize,
}
impl Default for Limits {
	fn default() -> Self {
		Self {
			resident_bytes: 4 * 1024 * 1024,
			staging_bytes: 4 * 1024 * 1024,
			cache_slots: 64,
			read_ahead: 8,
			max_leases: 128,
			max_changes: 64,
			max_references: 128,
			max_operations: 32,
			call_bytes: 64 * 1024,
			pending_bytes: 4 * 1024 * 1024,
			ingress_bytes: 1024 * 1024,
			record_capacity: 8,
			max_reference_saves: 64,
			record_bytes: 64 * 1024,
			max_retentions: 128,
			max_continuations: 64,
			continuation_bytes: 64 * 1024,
			max_continuation_targets: 32,
			forward_reply_bytes: 16 * 1024,
		}
	}
}
impl Limits {
	pub(super) fn raw(self) -> ffi::GlowcapLoamLimits {
		ffi::GlowcapLoamLimits {
			resident_bytes: self.resident_bytes,
			staging_bytes: self.staging_bytes,
			cache_slots: self.cache_slots,
			read_ahead: self.read_ahead,
			max_leases: self.max_leases,
			max_changes: self.max_changes,
			max_references: self.max_references,
			max_operations: self.max_operations,
			call_bytes: self.call_bytes,
			pending_bytes: self.pending_bytes,
			ingress_bytes: self.ingress_bytes,
			record_capacity: self.record_capacity,
			max_reference_saves: self.max_reference_saves,
			record_bytes: self.record_bytes,
			max_retentions: self.max_retentions,
			max_continuations: self.max_continuations,
			continuation_bytes: self.continuation_bytes,
			max_continuation_targets: self.max_continuation_targets,
			forward_reply_bytes: self.forward_reply_bytes,
		}
	}
}
