//! Project the complete Rooms vocabulary without a second dependency authority.
use glowcap::{Result, loam::Policy};
use rooms_application::content::permissions::{IDENTITY, Permission};

/// A single identity always uses the full domain's stable bit ordering.
/// Interface applicability and exact target admission are separate contracts.
pub fn descriptor() -> Result<Policy> {
	if Permission::ALL.len() > 64 {
		return Err(glowcap::loam::refusal(
			"Rooms vocabulary exceeds shared policy capacity",
		));
	}
	let mut keys = [0u64; 64];
	let mut dependencies = [(0u64, 0u64); 64];
	let mut count = 0;
	for (slot, &permission) in Permission::ALL.iter().enumerate() {
		keys[slot] = permission.key();
		if let Some(required) = permission.prerequisite() {
			dependencies[count] = (permission.key(), required.key());
			count += 1;
		}
	}
	Policy::with_dependencies(IDENTITY, &keys[..Permission::ALL.len()], &[], &dependencies[..count])
}
