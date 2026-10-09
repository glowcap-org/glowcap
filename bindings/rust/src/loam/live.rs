//! Live lifetime activation runs through the attachment's ordinary work lane.
use super::{Attachment, check};
use crate::{Result, sys::loam as ffi};

/// Descriptive trusted startup metadata. These bytes contain no capability.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LiveMarker([u8; 33]);

impl LiveMarker {
	pub fn encode(self) -> [u8; 33] {
		self.0
	}
	pub fn decode(bytes: [u8; 33]) -> Self {
		Self(bytes)
	}
}

impl Attachment {
	/// Reserve capacity and begin a new lifetime. Drive normal attachment work
	/// and exact recovery until `live_marker` returns the committed marker.
	/// Live declarations refuse while startup is pending or failed.
	pub fn start_live(&self, prior: Option<LiveMarker>, capacity: u32) -> Result<()> {
		let owner = self.inner()?;
		owner.host.guard_handle()?;
		let prior = prior.map(|marker| ffi::GlowcapLoamObject { key: marker.0 });
		check(
			unsafe {
				ffi::glowcap_loam_live_start(
					owner.raw.get(),
					prior.as_ref().map_or(core::ptr::null(), |value| value as *const _),
					capacity,
				)
			},
			false,
		)?;
		owner.host.schedule_kick_or_record();
		Ok(())
	}

	/// None means startup still owns storage work or recovery. A marker names
	/// its new lifetime; it cannot restore authority from any prior lifetime.
	pub fn live_marker(&self) -> Result<Option<LiveMarker>> {
		let owner = self.inner()?;
		owner.host.guard_handle()?;
		let mut marker = ffi::GlowcapLoamObject { key: [0; 33] };
		let status = unsafe { ffi::glowcap_loam_live_marker(owner.raw.get(), &mut marker) };
		if status == crate::sys::WOULD_BLOCK {
			return Ok(None);
		}
		check(status, false)?;
		Ok(Some(LiveMarker(marker.key)))
	}
}

/// Confirmed marker and generation identify one Host lifetime. A marker name
/// alone remains stable across reopen and cannot fence ephemeral presentation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LiveIncarnation {
	marker: LiveMarker,
	generation: core::num::NonZeroU64,
}
impl LiveIncarnation {
	pub fn encode(self) -> [u8; 41] {
		let mut bytes = [0; 41];
		bytes[..33].copy_from_slice(&self.marker.encode());
		bytes[33..].copy_from_slice(&self.generation.get().to_be_bytes());
		bytes
	}
}
impl Attachment {
	/// Both values come from the same confirmed scope without yielding. Pending
	/// startup produces no incarnation, and failed startup preserves its refusal.
	pub fn live_incarnation(&self) -> Result<Option<LiveIncarnation>> {
		let Some(marker) = self.live_marker()? else {
			return Ok(None);
		};
		let owner = self.inner()?;
		owner.host.guard_handle()?;
		let mut generation = 0;
		check(
			unsafe { ffi::glowcap_loam_live_generation(owner.raw.get(), &mut generation) },
			false,
		)?;
		let generation = core::num::NonZeroU64::new(generation)
			.ok_or_else(|| super::refusal("invalid confirmed live generation"))?;
		Ok(Some(LiveIncarnation { marker, generation }))
	}
}
