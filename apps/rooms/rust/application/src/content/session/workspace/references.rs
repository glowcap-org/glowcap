//! Intent selects exact typed custody fields. Validation and local retirement
//! share this borrowed walk. Effect receipts own their independent occurrences.
use super::{Conversation, Directory, Intent, Invitation, InvitationAuthority, PostedLine};
use crate::content::session::custody::{Coordinate, Custody, FieldKey, References, Role};

pub(in crate::content::session) fn coordinate<K>(role: Role, key: FieldKey<K>) -> Coordinate {
	Coordinate {
		role,
		key: FieldKey::new(key.slot(), key.generation()),
	}
}
impl Directory {
	/// Validation and retirement share every exact directory selection.
	pub fn coordinates(&self) -> impl Iterator<Item = Coordinate> {
		[
			Some(coordinate(Role::DirectoryAccess, self.access)),
			self.name.map(|key| coordinate(Role::DirectoryName, key)),
			self.source.map(|key| coordinate(Role::SessionAccess, key)),
			self.inbox.map(|key| coordinate(Role::DirectoryInbox, key)),
		]
		.into_iter()
		.flatten()
	}
}
impl Conversation {
	/// Borrow this row's selections without restoring any capability or copying
	/// its payload. The fixed optional slots stay on the stack.
	pub fn coordinates(&self) -> impl Iterator<Item = Coordinate> + '_ {
		let (fields, lines): ([Option<Coordinate>; 10], &[PostedLine]) = match self {
			Self::Room(room) => (
				[
					room.access.map(|key| coordinate(Role::RoomAccess, key)),
					room.accepted.map(|key| coordinate(Role::AcceptedAccess, key)),
					room.seat.map(|key| coordinate(Role::RoomSeat, key)),
					room.subject.map(|key| coordinate(Role::RoomSubject, key)),
					room.files.map(|key| coordinate(Role::RoomFiles, key)),
					room.moderator.map(|key| coordinate(Role::RoomAccess, key)),
					room.control.map(|key| coordinate(Role::RoomControl, key)),
					room.source.map(|key| coordinate(Role::SessionAccess, key)),
					room.inbox.map(|key| coordinate(Role::RoomInbox, key)),
					room.public_entry
						.as_ref()
						.map(|entry| coordinate(Role::DirectoryAccess, entry.access)),
				],
				room.lines.as_slice(),
			),
			Self::Direct(direct) => (
				[
					direct.access.map(|key| coordinate(Role::DirectAccess, key)),
					direct.source.map(|key| coordinate(Role::SessionAccess, key)),
					direct.inbox.map(|key| coordinate(Role::DirectInbox, key)),
					None,
					None,
					None,
					None,
					None,
					None,
					None,
				],
				direct.lines.as_slice(),
			),
		};
		fields
			.into_iter()
			.flatten()
			.chain(lines.iter().map(|line| coordinate(Role::Line, line.handle)))
			.chain(
				match self {
					Self::Direct(row) => row.introduction.as_ref(),
					_ => None,
				}
				.into_iter()
				.flat_map(|witness| {
					[
						coordinate(Role::DirectoryAccess, witness.access),
						coordinate(Role::DirectoryName, witness.name),
						coordinate(Role::DirectoryInbox, witness.callback),
					]
				}),
			)
	}
}
impl Intent {
	/// Acquisition owns retirement of removed selections, independently of its
	/// bounded ingress page. The caller must hold ManageCustody and ReplaceWorkspace.
	/// One fixed-capacity scalar index of the candidate's occurrences replaces a
	/// full candidate walk per old field. Decoded row/line bounds cap its length.
	/// Count * size_of::<Coordinate>() owns the scratch bytes. It borrows no
	/// payload and dies in this callback, while old intent backing moves intact.
	/// Aliases selected by the candidate and unselected independent imports stay.
	/// Receipts own separate occurrences and are never consulted or released here.
	pub fn replace_configuration_retiring<R: References>(
		&mut self,
		next: Self,
		custody: &mut Custody<R>,
	) -> Result<(), super::InvalidIntent> {
		self.check_configuration(&next)?;
		next.validate(custody)?;
		if *self == next {
			return Ok(());
		}
		let order = |coordinate: &Coordinate| {
			(
				coordinate.role as usize,
				coordinate.key.slot().get(),
				coordinate.key.generation().get(),
			)
		};
		let mut selected = alloc::vec::Vec::with_capacity(next.coordinates().count());
		selected.extend(next.coordinates());
		selected.sort_unstable_by_key(order);
		selected.dedup();
		let previous = core::mem::replace(self, next);
		for coordinate in previous.coordinates() {
			if selected.binary_search_by_key(&order(&coordinate), order).is_err() {
				custody.remove(coordinate);
			}
		}
		Ok(())
	}
	/// Enumerate every custody selection in this intent. Coordinates describe
	/// already held fields. The walk neither grants nor restores authority.
	pub fn coordinates(&self) -> impl Iterator<Item = Coordinate> + '_ {
		self.directories
			.as_slice()
			.iter()
			.flat_map(Directory::coordinates)
			.chain(self.conversations.as_slice().iter().flat_map(Conversation::coordinates))
			.chain(self.invitations.as_slice().iter().flat_map(Invitation::coordinates))
			.chain(self.peering.as_slice().iter().flat_map(|row| {
				[
					coordinate(Role::RoomAccess, row.room),
					coordinate(Role::PublicationLease, row.lease),
				]
			}))
			.chain(self.archive.map(|key| coordinate(Role::ArchiveAccess, key)))
			.chain(self.archive_control.map(|key| coordinate(Role::ArchiveControl, key)))
			.chain(
				self.archive_shares
					.as_slice()
					.iter()
					.flat_map(super::ReceivedArchive::coordinates),
			)
			.chain(
				self.operators
					.as_slice()
					.iter()
					.map(|&key| coordinate(Role::Operator, key)),
			)
			.chain(self.operations.as_slice().iter().map(|row| row.handle))
			.chain(self.accesses.as_slice().iter().flat_map(|row| {
				[
					row.access.map(|key| coordinate(Role::SessionAccess, key)),
					row.control.map(|key| coordinate(Role::SessionControl, key)),
				]
				.into_iter()
				.flatten()
			}))
	}
}
impl InvitationAuthority {
	pub fn coordinate(self) -> Coordinate {
		match self {
			Self::Offer(key) => coordinate(Role::Offer, key),
			Self::RoomAccess(key) => coordinate(Role::RoomAccess, key),
		}
	}
}
impl Invitation {
	pub fn coordinates(&self) -> impl Iterator<Item = Coordinate> {
		[
			Some(self.authority.coordinate()),
			self.source.map(|key| coordinate(Role::SessionAccess, key)),
		]
		.into_iter()
		.flatten()
	}
}
