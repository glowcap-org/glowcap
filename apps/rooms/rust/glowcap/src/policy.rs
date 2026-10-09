//! Project the complete Rooms vocabulary without a second dependency authority.
use glowcap::{
	Result,
	loam::{KindRule, Policy},
};
use rooms_application::content::permissions::{IDENTITY, Permission};
use rooms_application::content::session;

/// A single identity always uses the full domain's stable bit ordering.
/// The registered session kind supports its declared interface. Other resource
/// kinds require their own application declarations before registration.
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
	let mut supported = [0u64; 64];
	for (slot, permission) in session::SUPPORTED.iter().enumerate() {
		supported[slot] = permission.key();
	}
	Policy::with_dependencies(IDENTITY, &keys[..Permission::ALL.len()], &[], &dependencies[..count])?.with_kinds(&[
		KindRule {
			kind: session::KIND,
			permissions: &supported[..session::SUPPORTED.len()],
			subtree_permissions: &supported[..session::SUPPORTED.len()],
		},
	])
}
