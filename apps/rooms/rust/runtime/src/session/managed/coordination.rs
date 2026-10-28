//! Workspace rows select membership workers. They never reconstruct authority.
//! The embedding calls reconcile on admitted workspace changes and closes this
//! aggregate before closing the session. No timer or second grant ledger exists.
use super::{Membership, Session};
use glowcap::{Argument, Result};
use rooms_application::content::session::{custody, workspace};
use rooms_glowcap::client::{Deadline, Tasks};
use std::collections::BTreeMap;
#[cfg(test)]
mod tests;

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum MembershipTarget {
	Discovery(String),
	Directory(String),
	Room(String),
	Direct(String),
}
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Kind {
	Discovery,
	Directory,
	Room,
	Direct,
}
impl MembershipTarget {
	fn key(&self) -> (Kind, &str) {
		match self {
			Self::Discovery(id) => (Kind::Discovery, id),
			Self::Directory(id) => (Kind::Directory, id),
			Self::Room(id) => (Kind::Room, id),
			Self::Direct(id) => (Kind::Direct, id),
		}
	}
}
pub enum MembershipEvent<'a> {
	DirectorySnapshot {
		snapshot: &'a rooms_application::directory::Snapshot,
		origin: &'a super::InboxOrigin,
	},
	DirectoryChanged {
		event: rooms_application::directory::Event,
		origin: &'a super::InboxOrigin,
	},
	Notification {
		arguments: &'a [Argument],
		/// The exact initiating workspace endpoint, already checked by the inbox.
		/// Consumers retain this occurrence when mediating returned files.
		origin: &'a super::InboxOrigin,
	},
	Direct {
		verb: &'a str,
		arguments: &'a [Argument],
		delivering: Option<glowcap::Session>,
		origin: &'a super::InboxOrigin,
	},
}
pub type MembershipReceiver = Box<dyn FnMut(MembershipEvent<'_>) -> core::result::Result<Argument, String>>;

/// Which domain consumers the embedding has installed. This selects workers,
/// never grants authority. Every selected row still uses its saved source.
#[derive(Clone, Copy)]
pub struct MembershipKinds {
	pub discovery: bool,
	pub directories: bool,
	pub rooms: bool,
	pub directs: bool,
}
impl MembershipKinds {
	pub const ALL: Self = Self {
		discovery: true,
		directories: true,
		rooms: true,
		directs: true,
	};
	pub const ROOMS: Self = Self {
		discovery: false,
		directories: true,
		rooms: true,
		directs: false,
	};
}

/// Presentation facts only. Failure retains the corresponding worker and its
/// original request. Another reconcile retries that worker, not its effect.
#[derive(Default)]
pub struct MembershipReport {
	pub ready: usize,
	pub failures: Vec<(MembershipTarget, glowcap::Error)>,
}
/// One nickname copy per directory, bounded by 32 UTF-16 units and the directory
/// capacity. It outlives the borrowed snapshot so user edits can retire a worker.
/// Assigned nicknames remain output and cannot invalidate this request identity.
#[derive(PartialEq, Eq)]
enum Origin {
	Direct {
		directory: workspace::Id,
		peer: workspace::Id,
		access: Option<custody::FieldKey<custody::DirectAccess>>,
		introduction: Option<workspace::Introduction>,
		source: custody::FieldKey<custody::SessionAccess>,
	},
	Directory {
		access: custody::FieldKey<custody::DirectoryAccess>,
		source: custody::FieldKey<custody::SessionAccess>,
		nick: rooms_application::fields::Text<32>,
		allocation: rooms_application::directory::registration::NicknameAllocation,
	},
	Room {
		directory: workspace::Id,
		nickname: workspace::RoomNickname,
		access: Option<custody::FieldKey<custody::RoomAccess>>,
		accepted: Option<custody::FieldKey<custody::AcceptedAccess>>,
		public_entry: Option<workspace::PublicEntry>,
		publication: Option<rooms_application::fields::Text<128, true>>,
		source: custody::FieldKey<custody::SessionAccess>,
	},
}
impl Origin {
	fn direct(row: &workspace::Direct) -> Option<Self> {
		if row.closed {
			return None;
		}
		Some(Self::Direct {
			directory: row.directory.clone(),
			peer: row.peer.clone(),
			access: row.access,
			introduction: row.introduction.clone(),
			source: row.source?,
		})
	}
	fn directory(row: &workspace::Directory) -> Option<Self> {
		if !row.registers() {
			return None;
		}
		Some(Self::Directory {
			access: row.access,
			source: row.source?,
			nick: row.nick.clone(),
			allocation: row.nick_allocation,
		})
	}
	fn room(row: &workspace::Room, directory: &workspace::Directory) -> Option<Self> {
		if !row.requests_membership() {
			return None;
		}
		Some(Self::Room {
			directory: row.directory.clone(),
			nickname: workspace::RoomNickname::from_directory(directory),
			access: row.access,
			accepted: row.accepted,
			public_entry: row.public_entry.clone(),
			publication: row.publication.clone(),
			source: row.source?,
		})
	}
}
struct Entry<P: Tasks> {
	origin: Origin,
	membership: Membership<P>,
}

/// One bounded registry of scalar row identity and membership handles. It
/// retains neither snapshots nor upstream capabilities. Startup is awaited in
/// order so rows sharing one initiating endpoint do not claim the same mutation
/// sequence. Live callbacks and receipt execution continue independently.
pub struct Memberships<P: Tasks> {
	entries: BTreeMap<MembershipTarget, Entry<P>>,
	kinds: MembershipKinds,
}
impl<P: Tasks> Default for Memberships<P> {
	fn default() -> Self {
		Self {
			entries: BTreeMap::new(),
			kinds: MembershipKinds::ALL,
		}
	}
}
impl<P: Tasks> Memberships<P> {
	pub fn with_kinds(kinds: MembershipKinds) -> Self {
		Self {
			kinds,
			..Self::default()
		}
	}
}
enum Desired<'a> {
	Direct(&'a workspace::Direct),
	Directory(&'a workspace::Directory),
	Room(&'a workspace::Room, &'a workspace::Directory),
}
impl Desired<'_> {
	fn origin(&self) -> Result<Origin> {
		match self {
			Self::Direct(row) => Origin::direct(row),
			Self::Directory(row) => Origin::directory(row),
			Self::Room(row, directory) => Origin::room(row, directory),
		}
		.ok_or_else(|| glowcap::loam::refusal("membership row has no bounded origin"))
	}
	fn matches(&self, origin: &Origin) -> bool {
		match (self, origin) {
			(
				Self::Direct(row),
				Origin::Direct {
					directory,
					peer,
					access,
					introduction,
					source,
				},
			) => {
				row.directory == *directory
					&& row.peer == *peer
					&& (introduction.is_some() || row.access == *access)
					&& row.introduction == *introduction
					&& row.source == Some(*source)
			}
			(
				Self::Directory(row),
				Origin::Directory {
					access,
					source,
					nick,
					allocation,
				},
			) => {
				row.access == *access
					&& row.source == Some(*source)
					&& row.nick == *nick
					&& row.nick_allocation == *allocation
			}
			(
				Self::Room(row, current_directory),
				Origin::Room {
					directory,
					nickname,
					access,
					accepted,
					public_entry,
					publication,
					source,
				},
			) => {
				row.directory == *directory
					&& nickname.matches_directory(current_directory)
					&& (row.access == *access || (access.is_some() && row.access.is_none() && row.seat.is_some()))
					&& row.accepted == *accepted
					&& row.public_entry == *public_entry
					&& row.publication == *publication
					&& row.source == Some(*source)
			}
			_ => false,
		}
	}
}
impl<P: Tasks + Deadline + Clone + 'static> Memberships<P> {
	/// Only an explicit outer retry opens a new attempt window for retained
	/// failed workers. Workspace wakes and recovery timers cannot renew it.
	pub(super) fn retry_failed(&self) {
		for entry in self.entries.values() {
			if entry.membership.retirement_status().is_none() && matches!(entry.membership.status(), Some(Err(_))) {
				entry.membership.retry();
			}
		}
	}
	/// Sample failures before reconciliation waits on another target's startup.
	/// Connection loss is already known by the session-owned worker. Restoring
	/// a sibling must not hide that fact from the embedding.
	pub(super) fn append_status(&self, report: &mut MembershipReport) {
		for (target, entry) in &self.entries {
			if let Some(result) = entry.membership.retirement_status() {
				if let Err(error) = result {
					report.failures.push((target.clone(), error));
				}
				continue;
			}
			match entry.membership.status() {
				Some(Err(error)) => report.failures.push((target.clone(), error)),
				Some(Ok(())) => report.ready += 1,
				None => {}
			}
		}
	}
	/// Pass the latest admitted intent. Every new worker independently checks its
	/// exact source and selection before installing or dispatching. Cancellation
	/// of this observer leaves each already-inserted worker in this registry.
	pub async fn reconcile(
		&mut self,
		session: &Session<P>,
		intent: &workspace::Intent,
		locator: &str,
		entropy: &mut dyn crate::entropy::Entropy,
		mut receive: impl FnMut(&MembershipTarget) -> MembershipReceiver,
	) -> MembershipReport {
		let mut report = MembershipReport::default();
		// One temporary index borrows row identities. Comparing every worker
		// with every payload row would make each chat update quadratic.
		let mut desired = BTreeMap::new();
		for row in intent.directories.as_slice() {
			if self.kinds.directories
				&& Origin::directory(row).is_some()
				&& let Some(id) = row.id.text().as_str()
			{
				desired.insert((Kind::Directory, id), Desired::Directory(row));
			}
		}
		for row in intent.conversations.as_slice() {
			if let workspace::Conversation::Direct(row) = row
				&& self.kinds.directs
				&& Origin::direct(row).is_some()
				&& let Some(id) = row.id.text().as_str()
			{
				desired.insert((Kind::Direct, id), Desired::Direct(row));
			}
			if let workspace::Conversation::Room(row) = row
				&& self.kinds.rooms
				&& row.requests_membership()
				&& row.source.is_some()
				&& let Some(directory) = workspace::RoomNickname::directory(intent, &row.directory)
				&& workspace::RoomNickname::settled(directory)
				&& let Some(id) = row.id.text().as_str()
			{
				desired.insert((Kind::Room, id), Desired::Room(row, directory));
			}
		}
		// Only one bounded identifier is copied across a retirement await.
		loop {
			let obsolete = self
				.entries
				.iter()
				.find(|(target, entry)| {
					!report.failures.iter().any(|(failed, _)| failed == *target)
						&& desired.get(&target.key()).is_none_or(|row| !row.matches(&entry.origin))
				})
				.map(|(target, _)| target.clone());
			let Some(target) = obsolete else { break };
			let Some(entry) = self.entries.get_mut(&target) else {
				// The failure keeps the target out of the next selection above.
				report.failures.push((
					target,
					glowcap::loam::refusal("membership left the registry before retirement"),
				));
				continue;
			};
			if let Err(error) = entry.membership.close().await {
				report.failures.push((target, error));
				continue;
			}
			self.entries.remove(&target);
		}
		self.entries.retain(|_, entry| entry.membership.is_active());
		for ((kind, id), row) in desired {
			let target = match kind {
				Kind::Discovery => unreachable!("discovery has an independent observation owner"),
				Kind::Directory => MembershipTarget::Directory(id.into()),
				Kind::Room => MembershipTarget::Room(id.into()),
				Kind::Direct => MembershipTarget::Direct(id.into()),
			};
			if report.failures.iter().any(|(failed, _)| failed == &target) {
				continue;
			}
			if let std::collections::btree_map::Entry::Vacant(entry) = self.entries.entry(target.clone()) {
				let origin = match row.origin() {
					Ok(origin) => origin,
					Err(error) => {
						report.failures.push((target, error));
						continue;
					}
				};
				let mut receiver = receive(&target);
				let membership = match row {
					Desired::Direct(row) => {
						session
							.supervise_direct(row, entropy, move |verb, arguments, delivering, origin| {
								receiver(MembershipEvent::Direct {
									verb,
									arguments,
									delivering,
									origin,
								})
							})
							.await
					}
					Desired::Directory(row) => {
						session
							.supervise_directory(row, locator, entropy, move |arguments, origin| {
								receiver(MembershipEvent::Notification { arguments, origin }).map(|_| ())
							})
							.await
					}
					Desired::Room(row, _) => {
						session
							.supervise_room(row, intent, entropy, move |arguments, origin| {
								receiver(MembershipEvent::Notification { arguments, origin }).map(|_| ())
							})
							.await
					}
				};
				match membership {
					Ok(membership) => {
						entry.insert(Entry { origin, membership });
					}
					Err(error) => {
						report.failures.push((target, error));
						continue;
					}
				}
			}
			self.readiness(&target, &mut report).await;
		}
		report
	}
	async fn readiness(&self, target: &MembershipTarget, report: &mut MembershipReport) {
		let Some(entry) = self.entries.get(target) else {
			report.failures.push((
				target.clone(),
				glowcap::loam::refusal("membership left the registry before readiness"),
			));
			return;
		};
		let membership = &entry.membership;
		if let Some(Err(error)) = membership.status() {
			let reason = error.to_string();
			let advice = rooms_application::failure::Failure::parse(&reason).and_then(|failure| failure.retry_advice());
			if advice.is_none() {
				membership.retry();
			}
		}
		// A successful retirement is an ordinary lifetime transition. Its
		// existing completion barrier retains actual cleanup failures.
		tokio::select! {
			biased;
			ended = membership.ended() => {
				if let Err(error) = ended {
					report.failures.push((target.clone(), error));
				}
			},
			ready = membership.ready() => match ready {
				Ok(()) => report.ready += 1,
				Err(error) => report.failures.push((target.clone(), error)),
			},
		}
	}
	/// A failed close keeps exact worker custody here. Retrying this method
	/// resumes those barriers. Successful sibling closures are already retired.
	pub async fn close(&mut self) -> Result<()> {
		let mut result: Result<()> = Ok(());
		for (target, entry) in &mut self.entries {
			if let Err(error) = entry.membership.close().await {
				let error = error.with_context(&format!("closing {target:?} membership"));
				result = match result {
					Ok(()) => Err(error),
					Err(first) => Err(first.with_cleanup(Err(error))),
				};
			}
		}
		self.entries.retain(|_, entry| entry.membership.is_active());
		result
	}
}
