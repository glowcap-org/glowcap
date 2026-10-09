//! Operations replacement fences its original bundle, preserving other intent.
use super::*;
use rooms_application::fields::List;
use rooms_application::server::operations::BOOT_CAPABILITIES;
use serde::{Deserialize, Serialize};
use std::cell::Cell;

/// Only bundle selections, never transient connection custody or bearer text.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OperationsSelection {
	pub operators: List<custody::FieldKey<custody::Operator>, 64>,
	pub operations: List<workspace::Operations, 64>,
}
impl OperationsSelection {
	/// Diagnose an import by its selected interface and exact field identity.
	pub fn capability_at(&self, coordinate: custody::Coordinate) -> Option<&'static str> {
		use rooms_application::session::operations::mutation::Kind;
		if coordinate.role == custody::Role::Operator {
			return self
				.operators
				.as_slice()
				.iter()
				.any(|key| key.slot() == coordinate.key.slot() && key.generation() == coordinate.key.generation())
				.then_some("operator");
		}
		let row = self.operations.as_slice().iter().find(|row| row.handle == coordinate)?;
		Some(match row.kind {
			Kind::Listeners => "listeners",
			Kind::Diagnostics => "diagnostics",
			Kind::Trace => "trace",
			Kind::Peering => "peering",
			Kind::IrcGateway => "irc",
			Kind::IrcConnection => return None,
		})
	}
	/// Each of the workspace's two 64-row inventories fits within 256 JSON
	/// bytes per scalar row, plus the object envelope. Connection rows are absent.
	pub const MAX_JSON_BYTES: usize = 2 * 64 * 256 + 64;
	fn validate(&self) -> glowcap::Result<()> {
		if self
			.operations
			.as_slice()
			.iter()
			.any(|row| row.connection.is_some() || !row.valid())
		{
			return Err(loam::refusal("invalid operations bundle selection"));
		}
		Ok(())
	}
	fn validate_replacement(&self) -> glowcap::Result<()> {
		self.validate()?;
		let rows = self.operations.as_slice();
		if self.operators.as_slice().len() > 1
			|| self.operators.as_slice().len() + rows.len() > BOOT_CAPABILITIES.len()
			|| rows
				.iter()
				.enumerate()
				.any(|(at, row)| rows[..at].iter().any(|prior| prior.kind == row.kind))
		{
			return Err(loam::refusal("invalid replacement operations bundle"));
		}
		Ok(())
	}
	pub fn from_intent(intent: &Intent) -> glowcap::Result<Self> {
		Ok(Self {
			operators: List::new(intent.operators.as_slice().to_vec())
				.ok_or_else(|| loam::refusal("operations selection exceeds workspace capacity"))?,
			operations: List::new(
				intent
					.operations
					.as_slice()
					.iter()
					.filter(|row| row.connection.is_none())
					.cloned()
					.collect(),
			)
			.ok_or_else(|| loam::refusal("operations selection exceeds workspace capacity"))?,
		})
	}
	fn unchanged(&self, intent: &Intent) -> bool {
		self.operators.as_slice() == intent.operators.as_slice()
			&& self.operations.as_slice().iter().eq(intent
				.operations
				.as_slice()
				.iter()
				.filter(|row| row.connection.is_none()))
	}
	fn compose(&self, intent: &Intent) -> glowcap::Result<Intent> {
		self.validate_replacement()?;
		let mut candidate = intent.clone();
		candidate.operators = List::new(self.operators.as_slice().to_vec()).unwrap();
		candidate.operations = List::new(self.operations.as_slice().to_vec()).unwrap();
		for row in intent.operations.as_slice() {
			if row.connection.as_ref().is_some_and(|connection| {
				self.operations
					.as_slice()
					.iter()
					.any(|gateway| gateway.handle == connection.gateway)
			}) {
				candidate
					.operations
					.try_push(row.clone())
					.map_err(|_| loam::refusal("operations selection capacity"))?;
			}
		}
		Ok(candidate)
	}
	fn heap_bytes(&self) -> usize {
		self.operators.capacity() * size_of::<custody::FieldKey<custody::Operator>>()
			+ self.operations.capacity() * size_of::<workspace::Operations>()
	}
}

/// Two bounded scalar selections survive alongside one immutable envelope.
/// Recomposition clones only a proved-rejected candidate's original imports;
/// capability guards share exact custody, and no recipe is fetched again.
pub struct OperationsAcquisition<D> {
	original: OperationsSelection,
	replacement: OperationsSelection,
	acquisition: Acquisition<D>,
	conflicted: Cell<bool>,
}
impl<D: Deadline + Clone> Workspace<D> {
	pub async fn prepare_operations(
		&self,
		imports: Vec<Import>,
		original: OperationsSelection,
		replacement: OperationsSelection,
	) -> Result<OperationsAcquisition<D>, Error> {
		original.validate()?;
		replacement.validate_replacement()?;
		let snapshot = self.snapshot().await?;
		if !original.unchanged(&snapshot.intent) {
			return Err(loam::refusal("the original operations selection changed").into());
		}
		let candidate = replacement.compose(&snapshot.intent)?;
		if imports.iter().any(|import| {
			!matches!(
				import.coordinate.role,
				custody::Role::Operator | custody::Role::Operations
			) || !candidate
				.coordinates()
				.any(|coordinate| coordinate == import.coordinate)
		}) {
			return Err(loam::refusal("operations imports must belong to the selected bundle").into());
		}
		Ok(OperationsAcquisition {
			original,
			replacement,
			acquisition: self.prepare_acquisition(snapshot.revision, imports, &[], &candidate)?,
			conflicted: Cell::new(false),
		})
	}
}
impl<D: Deadline + Clone> OperationsAcquisition<D> {
	pub fn retained_bytes(&self) -> usize {
		size_of::<Self>()
			+ self.original.heap_bytes()
			+ self.replacement.heap_bytes()
			+ self.acquisition.retained_bytes()
			- size_of::<Acquisition<D>>()
	}
	pub fn source(&self) -> &Ref {
		self.acquisition.source()
	}
	pub async fn submit(&self) -> Result<(), Error> {
		self.conflicted.set(false);
		let outcome = self.acquisition.submit().await;
		self.conflicted.set(matches!(outcome, Err(Error::WorkspaceConflict)));
		outcome
	}
	pub async fn reprepare(&self) -> Result<Self, Error> {
		if !self.conflicted.get() {
			return Err(loam::refusal("operations outcome is not a proved conflict").into());
		}
		let snapshot = self.acquisition.snapshot_source().await?;
		if !self.original.unchanged(&snapshot.intent) {
			return Err(loam::refusal("the original operations selection changed").into());
		}
		let candidate = self.replacement.compose(&snapshot.intent)?;
		Ok(Self {
			original: self.original.clone(),
			replacement: self.replacement.clone(),
			acquisition: self.acquisition.recompose(snapshot.revision, &candidate)?,
			conflicted: Cell::new(false),
		})
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use rooms_application::session::operations::mutation::Kind;
	use std::num::NonZeroU64;

	#[test]
	fn import_diagnosis_follows_interface_and_exact_field_identity() {
		let key = custody::FieldKey::new(NonZeroU64::new(1).unwrap(), NonZeroU64::new(2).unwrap());
		let mut coordinate = custody::Coordinate {
			role: custody::Role::Operations,
			key,
		};
		for (kind, capability) in [
			(Kind::Listeners, Some("listeners")),
			(Kind::Diagnostics, Some("diagnostics")),
			(Kind::Trace, Some("trace")),
			(Kind::Peering, Some("peering")),
			(Kind::IrcGateway, Some("irc")),
			(Kind::IrcConnection, None),
		] {
			let selection = OperationsSelection {
				operators: List::new(Vec::new()).unwrap(),
				operations: List::new(vec![workspace::Operations {
					kind,
					handle: coordinate,
					connection: None,
				}])
				.unwrap(),
			};
			assert_eq!(selection.capability_at(coordinate), capability);
			let stale = custody::Coordinate {
				key: custody::FieldKey::new(key.slot(), NonZeroU64::new(3).unwrap()),
				..coordinate
			};
			assert_eq!(selection.capability_at(stale), None);
		}
		let selection = OperationsSelection {
			operators: List::new(vec![custody::FieldKey::new(key.slot(), key.generation())]).unwrap(),
			operations: List::new(Vec::new()).unwrap(),
		};
		assert_eq!(selection.capability_at(coordinate), None);
		coordinate.role = custody::Role::Operator;
		assert_eq!(selection.capability_at(coordinate), Some("operator"));
		coordinate.key = custody::FieldKey::new(key.slot(), NonZeroU64::new(3).unwrap());
		assert_eq!(selection.capability_at(coordinate), None);
	}
}
