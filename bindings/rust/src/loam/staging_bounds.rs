//! Descriptive row allowances. Shared Store staging still admits every write.
use super::check;
use crate::{Result, sys::loam as ffi};

/// Retained encoded proposals, excluding temporary encoder buffers, Store
/// descriptors and backend metadata. Counts are unique rows in one transaction.
#[derive(Clone, Copy)]
pub struct StagingBounds {
	pub changes: usize,
	pub staging_bytes: usize,
	pub record_bytes: usize,
}
impl StagingBounds {
	/// One managed content effect, optionally with its mutation receipt and
	/// invoking endpoint. `resource_path` includes the target and its ancestors.
	/// Add application content/pages and fresh reference recipes separately.
	/// Creation, resource/control edits and multiple effects are other profiles.
	pub fn content(resource_path: usize, receipt: bool) -> Result<Self> {
		let mut raw = ffi::GlowcapLoamStagingBounds {
			changes: 0,
			staging_bytes: 0,
			record_bytes: 0,
		};
		check(
			// SAFETY: this query takes no handle; `raw` is a local `GlowcapLoamStagingBounds` out-parameter the callee
			// writes, and the other arguments are integers passed by value.
			unsafe { ffi::glowcap_loam_content_staging_size_bound(resource_path, u32::from(receipt), &mut raw) },
			false,
		)?;
		Ok(Self::from_raw(raw))
	}
	/// At most one canonical local/foreign recipe per fresh save. Reusing a
	/// committed field needs no new recipe. This query allocates and admits nothing.
	pub fn references(saves: usize) -> Result<Self> {
		let mut raw = ffi::GlowcapLoamStagingBounds {
			changes: 0,
			staging_bytes: 0,
			record_bytes: 0,
		};
		check(
			// SAFETY: this query takes no handle; `raw` is a local `GlowcapLoamStagingBounds` out-parameter the callee
			// writes, and `saves` is an integer passed by value.
			unsafe { ffi::glowcap_loam_reference_staging_size_bound(saves, &mut raw) },
			false,
		)?;
		Ok(Self::from_raw(raw))
	}
	fn from_raw(raw: ffi::GlowcapLoamStagingBounds) -> Self {
		Self {
			changes: raw.changes,
			staging_bytes: raw.staging_bytes,
			record_bytes: raw.record_bytes,
		}
	}
}
