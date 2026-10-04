//! Bounded policy descriptors. Zig owns validation and the policy algebra.
use super::{check, invalid};
use crate::sys::loam as ffi;
use crate::{Argument, Result};

#[derive(Clone, Copy)]
pub enum Operator {
	LowerBound,
	UpperBound,
}
#[derive(Clone)]
pub struct Policy {
	pub(super) raw: ffi::GlowcapLoamPolicy,
}
impl Policy {
	pub fn new(identity: [u8; 16], permissions: &[u64], constraints: &[(u64, Operator)]) -> Result<Self> {
		Self::with_dependencies(identity, permissions, constraints, &[])
	}
	/// Positive implications constrain configured terms and management ceilings.
	/// Each pair is (permission, prerequisite); effect requirements stay partial.
	pub fn with_dependencies(
		identity: [u8; 16],
		permissions: &[u64],
		constraints: &[(u64, Operator)],
		dependencies: &[(u64, u64)],
	) -> Result<Self> {
		if permissions.len() > 64 || constraints.len() > 16 || dependencies.len() > 64 * 64 {
			return Err(invalid("policy descriptor exceeds its fixed capacity"));
		}
		let mut raw: ffi::GlowcapLoamPolicy = unsafe { core::mem::zeroed() };
		raw.identity = identity;
		raw.permission_count = permissions.len();
		raw.constraint_count = constraints.len();
		raw.permissions[..permissions.len()].copy_from_slice(permissions);
		for (slot, (key, operator)) in raw.constraints.iter_mut().zip(constraints) {
			*slot = ffi::GlowcapLoamConstraint {
				key: *key,
				operator: match operator {
					Operator::LowerBound => 0,
					Operator::UpperBound => 1,
				},
			};
		}
		for &(permission, required) in dependencies {
			let index = permissions
				.iter()
				.position(|&key| key == permission)
				.ok_or_else(|| invalid("unknown dependent permission"))?;
			let required = permissions
				.iter()
				.position(|&key| key == required)
				.ok_or_else(|| invalid("unknown prerequisite"))?;
			let bit = 1u64 << required;
			if raw.prerequisite_masks[index] & bit != 0 {
				return Err(invalid("duplicate permission dependency"));
			}
			raw.prerequisite_masks[index] |= bit;
		}
		let value = Self { raw };
		value.value(&[], &[])?;
		Ok(value)
	}
	pub fn value(&self, permissions: &[u64], bounds: &[(u64, u64)]) -> Result<PolicyValue> {
		let requirement = Requirement::new(permissions, bounds)?;
		let mut raw: ffi::GlowcapLoamPolicyValue = unsafe { core::mem::zeroed() };
		check(
			unsafe { ffi::glowcap_loam_policy_value(&self.raw, &requirement.raw, &mut raw) },
			false,
		)?;
		Ok(PolicyValue { raw })
	}
}
#[derive(Clone, Copy)]
pub struct PolicyValue {
	raw: ffi::GlowcapLoamPolicyValue,
}
impl PolicyValue {
	/// Arguments for the shared `derive` method, including its receipt sequence.
	pub fn derive_arguments(self, sequence: u32, depth: u16) -> Vec<Argument> {
		self.derivation_arguments(sequence, depth, None)
	}
	/// Arguments for `derive-managed`, returning [use Ref, child control Ref].
	/// Editing and lifecycle powers are explicit and admitted by the shared engine.
	pub fn managed_derive_arguments(self, sequence: u32, depth: u16, powers: ControlPowers) -> Vec<Argument> {
		self.derivation_arguments(sequence, depth, Some(powers))
	}
	/// Arguments for `mutate(sequence, "set-policy", ...)` on a held control.
	/// The control supplies scope; the policy cannot exceed its editing ceiling.
	pub fn set_policy_arguments(self, sequence: u32) -> Vec<Argument> {
		let mut args = Vec::with_capacity(5);
		args.push(Argument::Integer(i64::from(sequence)));
		args.push(Argument::String("set-policy".into()));
		self.append_arguments(&mut args);
		args
	}
	/// One final argument spine and bounded owned leaves survive the caller's
	/// Session future. Reserve the exact spine; no temporary policy Vec or growth
	/// reallocation participates in building a derivation or mutation request.
	fn derivation_arguments(self, sequence: u32, depth: u16, powers: Option<ControlPowers>) -> Vec<Argument> {
		let mut args = Vec::with_capacity(if powers.is_some() { 6 } else { 5 });
		args.push(Argument::Integer(i64::from(sequence)));
		self.append_arguments(&mut args);
		args.push(Argument::Integer(i64::from(depth)));
		if let Some(powers) = powers {
			args.push(powers.argument());
		}
		args
	}
	fn append_arguments(self, args: &mut Vec<Argument>) {
		let bounds = (0..16)
			.map(|i| {
				if self.raw.bound_mask & (1 << i) == 0 {
					Argument::Void
				} else {
					Argument::Bytes(self.raw.bounds[i].to_be_bytes().to_vec())
				}
			})
			.collect();
		args.push(Argument::Bytes(self.raw.identity.to_vec()));
		args.push(Argument::List(vec![Argument::Bytes(
			self.raw.permissions.to_be_bytes().to_vec(),
		)]));
		args.push(Argument::List(bounds));
	}
}

/// Independently attenuable management authority. `None` denies policy edits;
/// lifecycle powers do not imply editing, delegation or content use authority.
#[derive(Clone, Copy, Default)]
pub struct ControlPowers {
	pub policy_ceiling: Option<PolicyValue>,
	pub pause: bool,
	pub resume: bool,
	pub revoke: bool,
}
impl ControlPowers {
	/// Arguments for receipt-backed `mutate(sequence, "attenuate-control", ...)`.
	/// The returned control depends on this control, while use remains independent.
	pub fn attenuation_arguments(self, sequence: u32) -> Vec<Argument> {
		vec![
			Argument::Integer(i64::from(sequence)),
			Argument::String("attenuate-control".into()),
			self.argument(),
		]
	}
	fn argument(self) -> Argument {
		let ceiling = self.policy_ceiling.map_or(Argument::Void, |policy| {
			let mut args = Vec::with_capacity(3);
			policy.append_arguments(&mut args);
			Argument::List(args)
		});
		let mask = i64::from(self.pause) | (i64::from(self.resume) << 1) | (i64::from(self.revoke) << 2);
		Argument::List(vec![ceiling, Argument::Integer(mask)])
	}
}
pub struct Requirement {
	pub(super) raw: ffi::GlowcapLoamRequirement,
}
impl Requirement {
	pub fn new(permissions: &[u64], facts: &[(u64, u64)]) -> Result<Self> {
		if permissions.len() > 64 || facts.len() > 16 {
			return Err(invalid("requirement exceeds its fixed capacity"));
		}
		let mut raw: ffi::GlowcapLoamRequirement = unsafe { core::mem::zeroed() };
		raw.permission_count = permissions.len();
		raw.fact_count = facts.len();
		raw.permissions[..permissions.len()].copy_from_slice(permissions);
		for (slot, (key, value)) in raw.facts.iter_mut().zip(facts) {
			*slot = ffi::GlowcapLoamBound {
				key: *key,
				value: *value,
			};
		}
		Ok(Self { raw })
	}
}
