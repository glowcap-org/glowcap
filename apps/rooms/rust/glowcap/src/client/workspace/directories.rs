//! Directory acquisition commits its exact initiating endpoint with the target.
//! Display routes never select session authority or synthesize a stronger grant.
use super::*;
use std::cell::Cell;

/// An immutable directory candidate also owns its rejected-addition recipe.
/// Re-preparation uses the original acquired endpoint, source and coordinates.
/// It never fetches the display route again.
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
		// An interrupted replay cannot inherit proof from an earlier refusal. status-allow: event or source ordering
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
		let (candidate, released) = candidate(&snapshot.intent, self.row.clone())?;
		Ok(Self {
			row: self.row.clone(),
			acquisition: self
				.acquisition
				.recompose(snapshot.revision, released.as_slice(), &candidate)?,
			conflicted: Cell::new(false),
		})
	}
}

/// The intent a directory row installs, and the access coordinate it releases.
/// A new id is added. A held id re-routes that directory: the new access
/// replaces the held one under the same id and initiating source, the held
/// coordinate leaves custody, and the directory keeps its home mark and
/// standing. The held access coordinate again changes nothing, so it is
/// refused before any effect.
fn candidate(intent: &Intent, row: workspace::Directory) -> glowcap::Result<(Intent, Option<custody::Coordinate>)> {
	let mut candidate = intent.clone();
	let held = candidate
		.directories
		.as_slice()
		.iter()
		.position(|existing| existing.id == row.id);
	let released = match held {
		Some(index) => {
			let existing = &mut candidate.directories.as_mut_slice()[index];
			if existing.source != row.source {
				return Err(loam::refusal("a re-routed directory keeps its initiating source"));
			}
			if existing.access == row.access {
				return Err(loam::refusal("a re-routed directory needs a new access coordinate"));
			}
			let released = custody::Coordinate::new(custody::Role::DirectoryAccess, existing.access);
			let home = existing.home || row.home;
			let standing = existing.standing.take();
			*existing = workspace::Directory { home, standing, ..row };
			Some(released)
		}
		None => {
			candidate
				.directories
				.try_push(row)
				.map_err(|_| loam::refusal("directory capacity is exhausted"))?;
			None
		}
	};
	let installed = held.unwrap_or(candidate.directories.as_slice().len() - 1);
	if candidate.directories.as_slice()[installed].home {
		for (index, existing) in candidate.directories.as_mut_slice().iter_mut().enumerate() {
			existing.home = index == installed;
		}
	}
	Ok((candidate, released))
}

pub struct DirectoryImport {
	pub row: workspace::Directory,
	pub reference: Ref,
	pub uri: Option<String>,
}
impl<D: Deadline + Clone> Workspace<D> {
	/// Prepare one immutable candidate over a supplied snapshot. The caller
	/// chooses fresh coordinates. This client supplies the actual source occurrence.
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
		let (candidate, released) = candidate(intent, row.clone())?;
		let mut imports = vec![Import {
			coordinate: custody::Coordinate::new(custody::Role::DirectoryAccess, access),
			reference,
			uri,
		}];
		// A new directory also imports the session access it is acquired
		// through. A re-routed one keeps the source it already holds.
		if released.is_none() {
			imports.push(Import {
				coordinate: custody::Coordinate::new(custody::Role::SessionAccess, source),
				reference: self.reference.clone(),
				uri: None,
			});
		}
		let acquisition = self.prepare_acquisition(expected, imports, released.as_slice(), &candidate)?;
		Ok(DirectoryAcquisition {
			row,
			acquisition,
			conflicted: Cell::new(false),
		})
	}
}
