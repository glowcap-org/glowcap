//! Borrowed descriptions of the shared source and its durable observation.
use super::{ControlDescription, PolicyDescription, invalid};
use crate::{Argument, Result};

/// Authenticated context position, without resource or invocation authority.
pub type ObservationCursor = [u8; 56];

#[derive(Clone, Copy, Debug)]
pub struct UseSnapshot<'a> {
	pub policy_id: u128,
	pub ceiling: PolicyDescription<'a>,
	pub configured: PolicyDescription<'a>,
	pub effective: PolicyDescription<'a>,
	pub delegation_depth: u16,
}

#[derive(Clone, Copy, Debug)]
pub enum UseDescription<'a> {
	Active(UseSnapshot<'a>),
	Paused,
	Revoked,
	OutOfScope,
}
impl<'a> UseDescription<'a> {
	pub fn read(value: &'a Argument) -> Result<Self> {
		let Argument::Tagged { tag, value } = value else {
			return Err(invalid("access description required"));
		};
		if tag != "access:description" {
			return Err(invalid("access description required"));
		}
		match value.as_slice() {
			[Argument::Symbol(status)] => match status.as_str() {
				"paused" => Ok(Self::Paused),
				"revoked" => Ok(Self::Revoked),
				"out_of_scope" => Ok(Self::OutOfScope),
				_ => Err(invalid("invalid inactive access description")),
			},
			[Argument::Symbol(status), schema, ceiling, configured, effective, depth] if status == "active" => {
				let policy_id = match schema {
					Argument::Integer(value) => {
						u128::try_from(*value).map_err(|_| invalid("negative policy identity"))?
					}
					Argument::BigInteger {
						negative: false,
						digits,
					} => digits.parse().map_err(|_| invalid("invalid policy identity"))?,
					_ => return Err(invalid("policy identity required")),
				};
				let delegation_depth = depth
					.as_i64()
					.and_then(|value| u16::try_from(value).ok())
					.ok_or_else(|| invalid("invalid delegation depth"))?;
				Ok(Self::Active(UseSnapshot {
					policy_id,
					ceiling: PolicyDescription::read(ceiling)?,
					configured: PolicyDescription::read(configured)?,
					effective: PolicyDescription::read(effective)?,
					delegation_depth,
				}))
			}
			_ => Err(invalid("invalid access description")),
		}
	}
}
#[derive(Clone, Copy, Debug)]
pub enum ObservedDescription<'a> {
	Use(UseDescription<'a>),
	Control(ControlDescription<'a>),
}
#[derive(Clone, Copy, Debug, Default)]
pub struct ObservationNotices {
	pub access: bool,
	pub target: bool,
	pub inventory: bool,
	pub management: bool,
	/// Something below the target changed. Only a grant whose own scope covers
	/// the target's subtree receives this.
	pub subtree: bool,
}
#[derive(Clone, Copy, Debug)]
pub struct ObservationDescription<'a> {
	/// Opaque authenticated context cursor. Copy only when retaining a request
	/// beyond the reply owner. It carries no resource or invocation authority.
	pub cursor: &'a ObservationCursor,
	pub source: ObservedDescription<'a>,
	pub resync: bool,
	pub changed: bool,
	pub notices: ObservationNotices,
}
impl<'a> ObservationDescription<'a> {
	pub fn read(value: &'a Argument) -> Result<Self> {
		let Argument::Tagged { tag, value } = value else {
			return Err(invalid("observation description required"));
		};
		if tag != "access:observation" {
			return Err(invalid("observation description required"));
		}
		let [
			cursor,
			source,
			Argument::Boolean(resync),
			Argument::Boolean(changed),
			Argument::List(flags),
		] = value.as_slice()
		else {
			return Err(invalid("invalid observation description"));
		};
		let cursor = cursor
			.as_bytes()
			.and_then(|bytes| bytes.try_into().ok())
			.ok_or_else(|| invalid("invalid observation cursor"))?;
		let source = match source {
			Argument::Tagged { tag, .. } if tag == "access:description" => {
				ObservedDescription::Use(UseDescription::read(source)?)
			}
			_ => ObservedDescription::Control(ControlDescription::read(source)?),
		};
		if flags.len() > 5 {
			return Err(invalid("invalid observation notices"));
		}
		let mut notices = ObservationNotices::default();
		for flag in flags {
			let Argument::Symbol(flag) = flag else {
				return Err(invalid("invalid observation notice"));
			};
			let selected = match flag.as_str() {
				"access" => &mut notices.access,
				"target" => &mut notices.target,
				"inventory" => &mut notices.inventory,
				"management" => &mut notices.management,
				"subtree" => &mut notices.subtree,
				_ => return Err(invalid("unknown observation notice")),
			};
			if *selected {
				return Err(invalid("duplicate observation notice"));
			}
			*selected = true;
		}
		Ok(Self {
			cursor,
			source,
			resync: *resync,
			changed: *changed,
			notices,
		})
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	fn tagged(tag: &str, value: Vec<Argument>) -> Argument {
		Argument::Tagged { tag: tag.into(), value }
	}
	fn observation(source: Argument, flags: Vec<Argument>) -> Argument {
		tagged(
			"access:observation",
			vec![
				Argument::Bytes(vec![0; 56]),
				source,
				true.into(),
				true.into(),
				Argument::List(flags),
			],
		)
	}
	#[test]
	fn active_observation_preserves_u128_policy_identity_and_borrows_reply_cursor() {
		let policy = tagged(
			"access:policy",
			vec![Argument::List(vec![1.into()]), Argument::List(vec![])],
		);
		let source = tagged(
			"access:description",
			vec![
				Argument::Symbol("active".into()),
				Argument::BigInteger {
					negative: false,
					digits: u128::MAX.to_string(),
				},
				policy.clone(),
				policy.clone(),
				policy,
				65535.into(),
			],
		);
		let reply = observation(source, vec![Argument::Symbol("target".into())]);
		let view = ObservationDescription::read(&reply).unwrap();
		let ObservedDescription::Use(UseDescription::Active(source)) = view.source else {
			panic!("active use")
		};
		assert_eq!(source.policy_id, u128::MAX);
		assert_eq!(source.delegation_depth, u16::MAX);
		assert!(view.notices.target);
		let Argument::Tagged { value, .. } = &reply else {
			unreachable!()
		};
		assert_eq!(view.cursor.as_ptr(), value[0].as_bytes().unwrap().as_ptr());
	}
	#[test]
	fn observation_rejects_inactive_disclosure_duplicate_flags_and_wrong_cursor_shape() {
		let inactive = || tagged("access:description", vec![Argument::Symbol("paused".into())]);
		let reply = observation(inactive(), vec![]);
		assert!(matches!(
			ObservationDescription::read(&reply).unwrap().source,
			ObservedDescription::Use(UseDescription::Paused)
		));
		let leaking = tagged(
			"access:description",
			vec![Argument::Symbol("paused".into()), true.into()],
		);
		assert!(ObservationDescription::read(&observation(leaking, vec![])).is_err());
		assert!(
			ObservationDescription::read(&observation(inactive(), vec![Argument::Symbol("access".into()); 2])).is_err()
		);
		let mut reply = observation(inactive(), vec![]);
		let Argument::Tagged { value, .. } = &mut reply else {
			unreachable!()
		};
		value[0] = Argument::Bytes(vec![0; 55]);
		assert!(ObservationDescription::read(&reply).is_err());
	}
}
