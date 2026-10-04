//! Session schema declarations shared by metadata and contract proofs. Runtime
//! adoption requires shared saved-reference and management operations first.
pub mod custody;
pub mod records;
pub mod requirements;
pub mod workspace;
use super::permissions::{InvalidPolicy, Permission, validate};
use crate::fields::List;
use Permission::*;
use alloc::vec::Vec;
use serde::{Deserialize, Deserializer, Serialize, de::Error};

pub const VERSION: u16 = 1;
pub const SUPPORTED: &[Permission] = &[
	History,
	ReadFile,
	ObserveWorkspace,
	InteractWorkspace,
	ReplaceWorkspace,
	ManageCustody,
	ResolvePending,
	UseOperations,
	ReadArchive,
];

/// Explicit configured values; no stored preset name or effective policy cache.
/// Session history is a projection gate. Each upstream conversation retains its
/// own canonical identity, generation and history boundary.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct Terms(List<Permission, { SUPPORTED.len() }>);
impl Terms {
	pub fn new(values: &[Permission]) -> Result<Self, InvalidPolicy> {
		validate(values, SUPPORTED)?;
		let ordered = Permission::ALL.iter().copied().filter(|p| values.contains(p)).collect();
		Ok(Self(List::new(ordered).expect("validated supported permissions")))
	}
	pub fn permissions(&self) -> &[Permission] {
		self.0.as_slice()
	}
	/// Prepare a complete candidate; refusal leaves the original terms unchanged.
	/// No prerequisite or management power is silently added by a preset.
	pub fn apply(&self, preset: Preset) -> Result<Self, InvalidPolicy> {
		let fields = preset.group().fields();
		let mut values = Vec::with_capacity(SUPPORTED.len());
		values.extend(self.permissions().iter().copied().filter(|p| !fields.contains(p)));
		values.extend_from_slice(preset.values());
		Self::new(&values)
	}
}
impl<'de> Deserialize<'de> for Terms {
	fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
		let values = List::<Permission, { SUPPORTED.len() }>::deserialize(d)?;
		Self::new(values.as_slice()).map_err(D::Error::custom)
	}
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Group {
	Participation,
	Custody,
}
impl Group {
	pub const ALL: &'static [Self] = &[Self::Participation, Self::Custody];
	pub const fn fields(self) -> &'static [Permission] {
		match self {
			Self::Participation => &[ObserveWorkspace, InteractWorkspace],
			Self::Custody => &[ReplaceWorkspace, ManageCustody, ResolvePending, UseOperations],
		}
	}
	pub fn matching(self, terms: &Terms) -> Option<Preset> {
		Preset::ALL.iter().copied().find(|p| {
			p.group() == self
				&& self
					.fields()
					.iter()
					.all(|field| terms.permissions().contains(field) == p.values().contains(field))
		})
	}
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Preset {
	Observer,
	Collaborator,
	NoCustody,
	Administrator,
}
impl Preset {
	pub const ALL: &'static [Self] = &[Self::Observer, Self::Collaborator, Self::NoCustody, Self::Administrator];
	pub const fn group(self) -> Group {
		match self {
			Self::Observer | Self::Collaborator => Group::Participation,
			Self::NoCustody | Self::Administrator => Group::Custody,
		}
	}
	pub const fn values(self) -> &'static [Permission] {
		match self {
			Self::Observer => &[ObserveWorkspace],
			Self::Collaborator => &[ObserveWorkspace, InteractWorkspace],
			Self::NoCustody => &[],
			Self::Administrator => Group::Custody.fields(),
		}
	}
	pub const fn label(self) -> &'static str {
		match self {
			Self::Observer => "Observer",
			Self::Collaborator => "Collaborator",
			Self::NoCustody => "None",
			Self::Administrator => "Administrator",
		}
	}
	pub const fn description(self) -> &'static str {
		match self {
			Self::Observer => "Observe live workspace state.",
			Self::Collaborator => "Observe and change workspace intent through held target authority.",
			Self::NoCustody => "No workspace replacement, custody, recovery or operations powers.",
			Self::Administrator => {
				"Replace workspace intent, manage custody, resolve pending effects and use held operators."
			}
		}
	}
}
