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
	/// Whether the row re-routes a held directory. The acquisition imports
	/// what that shape needs, so a replay keeps the shape or refuses.
	rerouting: bool,
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
		let (candidate, released) = install(&snapshot.intent, self.row.clone())?;
		if released.is_some() != self.rerouting {
			return Err(loam::refusal(if self.rerouting {
				"the directory being re-routed is no longer held; reach it again"
			} else {
				"the directory is held now; reach it again"
			})
			.into());
		}
		Ok(Self {
			row: self.row.clone(),
			acquisition: self
				.acquisition
				.recompose(snapshot.revision, released.as_slice(), &candidate)?,
			rerouting: self.rerouting,
			conflicted: Cell::new(false),
		})
	}
}

/// The intent a directory row installs, and the access coordinate it releases.
/// A new id is added. A held id re-routes that directory: the new access
/// replaces the held one under the same id and initiating source, and the
/// held coordinate leaves custody. The directory is the same one through
/// another door, so it keeps its home mark, standing, name, inbox, and the
/// nickname the directory assigned, that last one only while the nickname
/// asked for stays the same. The held access coordinate again changes
/// nothing, so it is refused before any effect.
fn install(intent: &Intent, row: workspace::Directory) -> glowcap::Result<(Intent, Option<custody::Coordinate>)> {
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
			let assigned_nick = (existing.nick == row.nick)
				.then(|| existing.assigned_nick.take())
				.flatten();
			*existing = workspace::Directory {
				home: existing.home || row.home,
				standing: existing.standing.take(),
				name: existing.name,
				inbox: existing.inbox,
				assigned_nick,
				..row
			};
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
		let (candidate, released) = install(intent, row.clone())?;
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
			rerouting: released.is_some(),
			conflicted: Cell::new(false),
		})
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use rooms_application::fields::Text;
	use std::num::NonZeroU64;

	fn key<K>(slot: u64) -> custody::FieldKey<K> {
		custody::FieldKey::new(NonZeroU64::new(slot).unwrap(), NonZeroU64::new(1).unwrap())
	}
	fn row(id: &str, access: u64, nick: &str) -> workspace::Directory {
		workspace::Directory {
			id: Text::new(id.into()).unwrap(),
			access: key(access),
			name: None,
			source: Some(key(1)),
			inbox: None,
			home: false,
			nick: Text::new(nick.into()).unwrap(),
			assigned_nick: None,
			nick_allocation: Default::default(),
			standing: None,
		}
	}

	#[test]
	fn a_reroute_keeps_the_directory_and_replaces_only_its_door() {
		let mut intent = Intent::empty();
		let mut held = row("d", 10, "ada");
		held.home = true;
		held.name = Some(key(11));
		held.inbox = Some(key(12));
		held.assigned_nick = Some(Text::new("ada2".into()).unwrap());
		held.standing = Some(Text::new("away".into()).unwrap());
		intent.directories.try_push(held.clone()).unwrap();

		let (rerouted, released) = install(&intent, row("d", 20, "ada")).unwrap();
		assert_eq!(
			released,
			Some(custody::Coordinate::new(custody::Role::DirectoryAccess, held.access))
		);
		let current = &rerouted.directories.as_slice()[0];
		assert_eq!(current.access, key(20));
		assert!(current.home, "the home mark was dropped");
		assert_eq!(current.name, held.name);
		assert_eq!(current.inbox, held.inbox);
		assert_eq!(current.assigned_nick, held.assigned_nick);
		assert_eq!(current.standing, held.standing);

		// Another nickname asks the directory for a new assignment.
		let (renamed, _) = install(&intent, row("d", 20, "bob")).unwrap();
		assert_eq!(renamed.directories.as_slice()[0].assigned_nick, None);
		assert_eq!(renamed.directories.as_slice()[0].name, held.name);

		// The held door again, or another initiating source, changes nothing.
		assert!(install(&intent, row("d", 10, "ada")).is_err());
		let mut foreign = row("d", 20, "ada");
		foreign.source = Some(key(2));
		assert!(install(&intent, foreign).is_err());

		// A new directory is added beside the held one, and takes the home
		// mark only when it asks for it.
		let (added, released) = install(&intent, row("e", 30, "ada")).unwrap();
		assert_eq!(released, None);
		assert_eq!(added.directories.as_slice().len(), 2);
		assert!(added.directories.as_slice()[0].home);
		let mut home = row("e", 30, "ada");
		home.home = true;
		let (moved, _) = install(&intent, home).unwrap();
		assert!(!moved.directories.as_slice()[0].home);
		assert!(moved.directories.as_slice()[1].home);
	}
}
