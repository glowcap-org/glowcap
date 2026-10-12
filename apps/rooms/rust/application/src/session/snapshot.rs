//! Shared-session snapshot admission and facet projection. The adapter retains
//! CapTP argument custody. This owner retains only validated application data.
mod codec;
pub mod views;

use super::checkpoint::{Checkpoint, Routes};
pub use super::fields::{Field, Id, List, Nullable, Presence, SafeInteger, Text};
use crate::{
	grants::{Access, protocol::GrantView},
	room::ArgumentView,
	text::DocumentText,
};
use alloc::{rc::Rc, string::String, vec::Vec};
use views::*;

pub const MAX_TEXT_BYTES: usize = 900 * 1024;
pub const WIRE_FIELDS: usize = 12;
pub const MAX_ISSUES: usize = 368;

pub trait SnapshotArgument: ArgumentView {
	type Item<'a>: SnapshotArgument
	where
		Self: 'a;
	fn list(&self) -> Option<impl ExactSizeIterator<Item = Self::Item<'_>>>;
}
/// Constructs the binding's existing owned values directly. No parallel CapTP
/// value tree or capability representation exists in the application.
pub trait BuildArguments {
	type Value;
	fn text(value: String) -> Self::Value;
	fn integer(value: u64) -> Self::Value;
	fn null() -> Self::Value;
	fn list(values: Vec<Self::Value>) -> Self::Value;
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
	Shape,
	Text,
	Json,
	Relation,
	Budget,
	Checkpoint,
}
impl core::fmt::Display for Refusal {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		write!(f, "invalid Rooms snapshot: {self:?}")
	}
}
impl core::error::Error for Refusal {}

pub struct Snapshot {
	pub revision: SafeInteger,
	pub checkpoint: Rc<Checkpoint>,
	pub pending_effects: List<Field, 256>,
	pub issues: List<(Field, Field), MAX_ISSUES>,
	pub connected_directories: List<Field, 32>,
	pub pending_effect_details: List<(Field, Field, Field, EffectPhase), 256>,
	pub member_locator: Nullable<Text<16384>>,
	pub room_views: List<RoomView, 256>,
	pub archive_shares: List<ArchiveShare, 16>,
	pub directory_views: List<DirectoryView, 32>,
	pub access: Access,
	pub workspace_adoption: Adoption,
	pub grants: List<GrantView, 32>,
	pub suspended_note: Option<DocumentText>,
	pub handed_rooms: List<HandedRoom, 16>,
}
impl Snapshot {
	pub fn read<A: SnapshotArgument>(args: &[A], routes: &impl Routes) -> Result<Self, Refusal> {
		codec::read(args, routes)
	}
	/// Write this already-projected view. Validation remains necessary because
	/// live view fields can be updated by their application owners.
	pub fn encode<B: BuildArguments>(&self) -> Result<Vec<B::Value>, Refusal> {
		codec::encode::<B>(self, None)
	}
	/// The caller supplies current policy. Extra issues describe this attachment
	/// and remain visible even when session access is suspended.
	pub fn project<B: BuildArguments>(
		&self,
		access: Access,
		note: &DocumentText,
		extra_issues: &[(Field, Field)],
	) -> Result<Vec<B::Value>, Refusal> {
		codec::encode::<B>(self, Some((access, note, extra_issues)))
	}
	fn validate(&self) -> Result<(), Refusal> {
		use alloc::collections::BTreeSet;
		let mut ids = BTreeSet::new();
		let mut count = 0;
		for room in &self.room_views.0 {
			if !ids.insert(&room.conversation_id.0) {
				return Err(Refusal::Relation);
			}
			count += room.members.0.len();
			let mut names = BTreeSet::new();
			if room.members.0.iter().any(|(name, _)| !names.insert(&name.0)) {
				return Err(Refusal::Relation);
			}
		}
		if count > 256 {
			return Err(Refusal::Relation);
		}
		ids.clear();
		count = 0;
		for directory in &self.directory_views.0 {
			if !ids.insert(&directory.directory_id.0) {
				return Err(Refusal::Relation);
			}
			count += directory.rooms.0.len() + directory.peers.0.len();
			let mut names = BTreeSet::new();
			for peer in &directory.peers.0 {
				if !super::fields::registration_id(&peer.registration_id) || !names.insert(peer.name.0.lowercase()) {
					return Err(Refusal::Relation);
				}
			}
			for room in &directory.rooms.0 {
				let valid = room.valid();
				if !valid {
					return Err(Refusal::Relation);
				}
			}
		}
		if count > 128 {
			return Err(Refusal::Relation);
		}
		let mut grants = BTreeSet::new();
		for grant in &self.grants.0 {
			grant.validate().map_err(|_| Refusal::Relation)?;
			if !grants.insert(&grant.id) {
				return Err(Refusal::Relation);
			}
		}
		Ok(())
	}
}
