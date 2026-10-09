//! Directory acquisition commits its exact initiating endpoint with the target.
//! Display routes never select session authority or synthesize a stronger grant.
use super::*;
use std::cell::Cell;

/// An immutable directory candidate also owns its rejected-addition recipe.
/// Re-preparation uses the original acquired endpoint, source and coordinates;
/// it never fetches the display route again or edits an existing directory row.
pub struct DirectoryAcquisition<D> {
	row: workspace::Directory,
	acquisition: Acquisition<D>,
	conflicted: Cell<bool>,
}
impl<D: Deadline + Clone> DirectoryAcquisition<D> {
	pub fn retained_bytes(&self) -> usize {
		size_of::<Self>()
			.saturating_add(self.acquisition.retained_bytes() - size_of::<Acquisition<D>>())
			.saturating_add(self.row.retained_bytes() - size_of::<workspace::Directory>())
	}
	pub fn source(&self) -> &Ref {
		self.acquisition.source()
	}
	pub async fn submit(&self) -> std::result::Result<(), Error> {
		// An interrupted replay cannot inherit proof from an earlier refusal.
		self.conflicted.set(false);
		let outcome = self.acquisition.submit().await;
		self.conflicted.set(matches!(outcome, Err(Error::WorkspaceConflict)));
		outcome
	}
	pub async fn reprepare(&self) -> std::result::Result<Self, Error> {
		if !self.conflicted.get() {
			return Err(loam::refusal("directory outcome is not a proved conflict").into());
		}
		let snapshot = self.acquisition.snapshot_source().await?;
		let candidate = addition(&snapshot.intent, self.row.clone())?;
		Ok(Self {
			row: self.row.clone(),
			acquisition: self.acquisition.recompose(snapshot.revision, &candidate)?,
			conflicted: Cell::new(false),
		})
	}
}

fn addition(intent: &Intent, row: workspace::Directory) -> glowcap::Result<Intent> {
	if intent
		.directories
		.as_slice()
		.iter()
		.any(|existing| existing.id == row.id)
	{
		return Err(loam::refusal(
			"directory row already exists; retain its original acquisition",
		));
	}
	let mut candidate = intent.clone();
	if row.home {
		for existing in candidate.directories.as_mut_slice() {
			existing.home = false;
		}
	}
	candidate
		.directories
		.try_push(row)
		.map_err(|_| loam::refusal("directory capacity is exhausted"))?;
	Ok(candidate)
}

pub struct DirectoryImport {
	pub row: workspace::Directory,
	pub reference: Ref,
	pub uri: Option<String>,
}
impl<D: Deadline + Clone> Workspace<D> {
	/// Prepare one immutable candidate over a supplied snapshot. The caller
	/// chooses fresh coordinates; this client supplies the actual source occurrence.
	/// A replay retains both capabilities and never fetches either again.
	pub fn prepare_directory(
		&self,
		expected: u64,
		directory: DirectoryImport,
		intent: &Intent,
	) -> glowcap::Result<DirectoryAcquisition<D>> {
		let DirectoryImport { row, reference, uri } = directory;
		let source = row
			.source
			.ok_or_else(|| loam::refusal("directory requires an initiating source coordinate"))?;
		if row.name.is_some() || row.inbox.is_some() || row.assigned_nick.is_some() {
			return Err(loam::refusal(
				"new directory cannot select a previous live registration",
			));
		}
		let nick = row
			.nick
			.text()
			.as_str()
			.ok_or_else(|| loam::refusal("invalid directory nickname"))?;
		if !nick.is_empty() && !rooms_application::room::inbox::valid_nick(nick) {
			return Err(loam::refusal("invalid directory nickname"));
		}
		// At most one bounded candidate is cloned. AcquisitionRequest serializes
		// it once, then drops this transient representation before any await.
		let access = row.access;
		let candidate = addition(intent, row.clone())?;
		let acquisition = self.prepare_acquisition(
			expected,
			vec![
				Import {
					coordinate: selected(custody::Role::DirectoryAccess, access),
					reference,
					uri,
				},
				Import {
					coordinate: selected(custody::Role::SessionAccess, source),
					reference: self.reference.clone(),
					uri: None,
				},
			],
			&[],
			&candidate,
		)?;
		Ok(DirectoryAcquisition {
			row,
			acquisition,
			conflicted: Cell::new(false),
		})
	}
}
fn selected<K>(role: custody::Role, key: custody::FieldKey<K>) -> custody::Coordinate {
	custody::Coordinate {
		role,
		key: custody::FieldKey::new(key.slot(), key.generation()),
	}
}
