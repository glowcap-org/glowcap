//! Borrowed views of shared management replies. No grant mirror or authority is
//! created: rows and ceilings remain descriptive data owned by the reply.
use super::invalid;
use crate::{Argument, Result};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AccessStatus {
	Active,
	Paused,
	Revoked,
}
impl AccessStatus {
	fn read(value: &Argument) -> Result<Self> {
		match value {
			Argument::Symbol(status) => match status.as_str() {
				"active" => Ok(Self::Active),
				"paused" => Ok(Self::Paused),
				"revoked" => Ok(Self::Revoked),
				_ => Err(invalid("unknown access status")),
			},
			_ => Err(invalid("access status symbol required")),
		}
	}
}
fn tagged<'a>(value: &'a Argument, expected: &str, count: usize) -> Result<&'a [Argument]> {
	match value {
		Argument::Tagged { tag, value } if tag == expected && value.len() == count => Ok(value),
		_ => Err(invalid("invalid management description")),
	}
}
fn unsigned(value: &Argument) -> Result<u64> {
	match value {
		Argument::Integer(value) => u64::try_from(*value).map_err(|_| invalid("negative management integer")),
		Argument::BigInteger {
			negative: false,
			digits,
		} => digits.parse().map_err(|_| invalid("management integer exceeds u64")),
		_ => Err(invalid("management integer required")),
	}
}
fn boolean(value: &Argument) -> Result<bool> {
	value.as_bool().ok_or_else(|| invalid("management Boolean required"))
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BoundOperator {
	Lower,
	Upper,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PolicyBound {
	pub key: u64,
	pub operator: BoundOperator,
	pub value: u64,
}
impl PolicyBound {
	fn read(value: &Argument) -> Result<Self> {
		let parts = tagged(value, "access:bound", 3)?;
		let operator = match &parts[1] {
			Argument::Symbol(value) if value == "lower" => BoundOperator::Lower,
			Argument::Symbol(value) if value == "upper" => BoundOperator::Upper,
			_ => return Err(invalid("invalid bound operator")),
		};
		Ok(Self {
			key: unsigned(&parts[0])?,
			operator,
			value: unsigned(&parts[2])?,
		})
	}
}
#[derive(Clone, Copy, Debug)]
pub struct PolicyDescription<'a> {
	permissions: &'a [Argument],
	bounds: &'a [Argument],
}
impl<'a> PolicyDescription<'a> {
	pub fn read(value: &'a Argument) -> Result<Self> {
		let parts = tagged(value, "access:policy", 2)?;
		let permissions = parts[0]
			.as_list()
			.filter(|rows| rows.len() <= 64)
			.ok_or_else(|| invalid("invalid policy permission list"))?;
		let bounds = parts[1]
			.as_list()
			.filter(|rows| rows.len() <= 16)
			.ok_or_else(|| invalid("invalid policy bound list"))?;
		for value in permissions {
			unsigned(value)?;
		}
		for value in bounds {
			PolicyBound::read(value)?;
		}
		Ok(Self { permissions, bounds })
	}
	pub fn permissions(&self) -> impl ExactSizeIterator<Item = u64> + 'a {
		self.permissions
			.iter()
			.map(|value| unsigned(value).expect("validated immutable permission"))
	}
	pub fn bounds(&self) -> impl ExactSizeIterator<Item = PolicyBound> + 'a {
		self.bounds
			.iter()
			.map(|value| PolicyBound::read(value).expect("validated immutable bound"))
	}
}
fn optional_policy(value: &Argument) -> Result<Option<PolicyDescription<'_>>> {
	if matches!(value, Argument::Boolean(false)) {
		Ok(None)
	} else {
		PolicyDescription::read(value).map(Some)
	}
}
#[derive(Clone, Copy, Debug)]
pub struct ControlSnapshot<'a> {
	pub status: AccessStatus,
	pub pause: bool,
	pub resume: bool,
	pub revoke: bool,
	pub edit_ceiling: Option<PolicyDescription<'a>>,
	pub subtree: bool,
	pub inspect: bool,
	pub issue_ceiling: Option<PolicyDescription<'a>>,
	pub delegate_control: bool,
	pub revision: u64,
}
#[derive(Clone, Copy, Debug)]
pub enum ControlDescription<'a> {
	Unavailable,
	Available(ControlSnapshot<'a>),
}
impl<'a> ControlDescription<'a> {
	pub fn read(value: &'a Argument) -> Result<Self> {
		if let Argument::Tagged { tag, value } = value
			&& tag == "access:control"
			&& matches!(value.as_slice(), [Argument::Symbol(status)] if status == "unavailable")
		{
			return Ok(Self::Unavailable);
		}
		let parts = tagged(value, "access:control", 10)?;
		Ok(Self::Available(ControlSnapshot {
			status: AccessStatus::read(&parts[0])?,
			pause: boolean(&parts[1])?,
			resume: boolean(&parts[2])?,
			revoke: boolean(&parts[3])?,
			edit_ceiling: optional_policy(&parts[4])?,
			subtree: boolean(&parts[5])?,
			inspect: boolean(&parts[6])?,
			issue_ceiling: optional_policy(&parts[7])?,
			delegate_control: boolean(&parts[8])?,
			revision: unsigned(&parts[9])?,
		}))
	}
}
/// Exact row identity is descriptive. It cannot retrieve a use or control
/// capability; mutations must address a control the caller actually holds.
#[derive(Clone, Copy, Debug)]
pub struct GrantDescription<'a> {
	pub slot: u32,
	pub generation: u64,
	pub revision: u64,
	pub label: &'a str,
	pub status: AccessStatus,
	pub effective_status: AccessStatus,
	pub ceiling: PolicyDescription<'a>,
	pub configured: PolicyDescription<'a>,
	pub delegation_depth: u16,
}
impl<'a> GrantDescription<'a> {
	pub fn read(value: &'a Argument) -> Result<Self> {
		let parts = tagged(value, "access:grant", 9)?;
		let label = parts[3]
			.as_str()
			.filter(|label| label.len() <= 120)
			.ok_or_else(|| invalid("invalid grant label"))?;
		Ok(Self {
			slot: u32::try_from(unsigned(&parts[0])?).map_err(|_| invalid("invalid grant slot"))?,
			generation: unsigned(&parts[1])?,
			revision: unsigned(&parts[2])?,
			label,
			status: AccessStatus::read(&parts[4])?,
			effective_status: AccessStatus::read(&parts[5])?,
			ceiling: PolicyDescription::read(&parts[6])?,
			configured: PolicyDescription::read(&parts[7])?,
			delegation_depth: u16::try_from(unsigned(&parts[8])?).map_err(|_| invalid("invalid delegation depth"))?,
		})
	}
}
#[derive(Clone, Copy, Debug)]
pub struct InventoryPage<'a> {
	rows: &'a [Argument],
	pub cursor: Option<&'a [u8]>,
}
impl<'a> InventoryPage<'a> {
	pub fn read(value: &'a Argument) -> Result<Self> {
		let parts = tagged(value, "access:inventory", 2)?;
		let rows = parts[0]
			.as_list()
			.filter(|rows| rows.len() <= 32)
			.ok_or_else(|| invalid("invalid inventory row count"))?;
		for row in rows {
			GrantDescription::read(row)?;
		}
		let cursor = match &parts[1] {
			Argument::Void => None,
			Argument::Bytes(bytes) if bytes.len() == 49 => Some(bytes.as_slice()),
			_ => return Err(invalid("invalid inventory cursor")),
		};
		Ok(Self { rows, cursor })
	}
	pub fn rows(&self) -> impl ExactSizeIterator<Item = GrantDescription<'a>> + 'a {
		self.rows
			.iter()
			.map(|row| GrantDescription::read(row).expect("validated immutable grant"))
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	fn number(digits: &str) -> Argument {
		Argument::BigInteger {
			negative: false,
			digits: digits.into(),
		}
	}
	fn policy() -> Argument {
		Argument::Tagged {
			tag: "access:policy".into(),
			value: vec![
				Argument::List(vec![10.into()]),
				Argument::List(vec![Argument::Tagged {
					tag: "access:bound".into(),
					value: vec![
						20.into(),
						Argument::Symbol("lower".into()),
						number("18446744073709551615"),
					],
				}]),
			],
		}
	}
	#[test]
	fn descriptions_preserve_large_unsigned_values_and_typed_bounds() {
		let policy = policy();
		let value = PolicyDescription::read(&policy).unwrap();
		assert_eq!(value.permissions().collect::<Vec<_>>(), vec![10]);
		assert_eq!(
			value.bounds().next().unwrap(),
			PolicyBound {
				key: 20,
				operator: BoundOperator::Lower,
				value: u64::MAX
			}
		);
		let control = Argument::Tagged {
			tag: "access:control".into(),
			value: vec![
				Argument::Symbol("paused".into()),
				true.into(),
				false.into(),
				true.into(),
				policy.clone(),
				false.into(),
				true.into(),
				policy,
				true.into(),
				number("18446744073709551615"),
			],
		};
		let ControlDescription::Available(snapshot) = ControlDescription::read(&control).unwrap() else {
			panic!("available")
		};
		assert_eq!(snapshot.revision, u64::MAX);
		assert_eq!(snapshot.status, AccessStatus::Paused);
		assert!(unsigned(&number("18446744073709551616")).is_err());
		assert!(unsigned(&(-1).into()).is_err());
	}
	#[test]
	fn management_projection_refuses_extra_disclosure_and_oversized_inventory() {
		let mut control = Argument::Tagged {
			tag: "access:control".into(),
			value: vec![Argument::Symbol("unavailable".into())],
		};
		assert!(matches!(
			ControlDescription::read(&control).unwrap(),
			ControlDescription::Unavailable
		));
		if let Argument::Tagged { value, .. } = &mut control {
			value.push(true.into());
		}
		assert!(ControlDescription::read(&control).is_err());
		let page = |rows, cursor| Argument::Tagged {
			tag: "access:inventory".into(),
			value: vec![Argument::List(rows), cursor],
		};
		let empty = page(vec![], Argument::Void);
		assert_eq!(InventoryPage::read(&empty).unwrap().rows().len(), 0);
		assert!(InventoryPage::read(&page(vec![], Argument::Bytes(vec![0; 50]))).is_err());
		assert!(InventoryPage::read(&page(vec![Argument::Void; 33], Argument::Void)).is_err());
		assert!(AccessStatus::read(&Argument::Symbol("unknown".into())).is_err());
	}
}
