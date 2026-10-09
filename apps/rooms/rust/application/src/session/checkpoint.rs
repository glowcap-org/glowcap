//! Validated version-one shared session checkpoints. Transport syntax stays
//! with the existing binding; document shape, relationships and visibility
//! belong here. Checkpoints retain bearer material; the requested facet decides
//! whether it leaves the owner.
use super::fields;
pub mod commands;
mod footprint;
pub mod gestures;
mod intent;
pub mod invitations;
mod model;
mod projection;
pub use intent::{
	BridgeIntent, DirectIntent, DirectoryIntent, OperationCredential, PeeringIntent, RoomIntent, RoomReconnect,
};
pub mod reconciliation;
mod validate;

use crate::grants::Access;
use alloc::string::String;

pub const MAX_CONVERSATIONS: usize = 256;
pub const MAX_CHECKPOINT_UNITS: usize = 512 * 1024;

/// Reopening the same registered peer names the history already kept for it.
/// Registration replacement gives a different identity, even if the nickname
/// is reused. This data identity grants no authority to revive a retired route.
pub fn direct_id(directory: &str, registration: &crate::directory::registration::Id) -> Option<fields::Id> {
	fields::Id::new(alloc::format!("direct:{directory}:{}", registration.as_str()).into())
}
/// Parse through the adapter's existing locator grammar, returning the Rooms
/// peer authority with reachability stripped. A sturdyref needs nonempty swiss.
pub trait Routes {
	fn locator_authority(&self, locator: &str) -> Option<String>;
	fn sturdyref_authority(&self, sturdyref: &str) -> Option<String>;
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
	Size,
	Schema,
	Relation,
	Route,
	Visualizer,
}
impl core::fmt::Display for Refusal {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		write!(f, "invalid Rooms checkpoint: {self:?}")
	}
}
impl core::error::Error for Refusal {}

#[derive(PartialEq, Eq)]
pub struct Checkpoint(model::State);
impl Checkpoint {
	pub fn uses_relay(&self) -> bool {
		self.0.dm_mode == model::DmMode::Relay
	}
	/// Retained graph size, including spare text/list capacity. Allocator metadata
	/// is excluded; callers separately bound the number of allocations/requests.
	pub fn retained_bytes(&self) -> usize {
		use footprint::HeapBytes;
		core::mem::size_of::<Self>().saturating_add(self.0.heap_bytes())
	}
	pub fn adoption_material(&self) -> Result<crate::text::DocumentText, Refusal> {
		serde_json::to_string(&("adoptWorkspace", self))
			.map(Into::into)
			.map_err(|_| Refusal::Schema)
	}
	pub fn empty() -> Self {
		Self(model::State::empty())
	}
	/// A browser fork is a new directory member. Preserve held room authority,
	/// drafts and preferences, but do not claim the original peer's names.
	pub fn fork(&self) -> Self {
		let mut state = self.0.clone();
		for directory in &mut state.directories.0 {
			directory.nick = fields::Field::new("".into()).expect("empty nickname");
		}
		state.join.nick = fields::Field::new("".into()).expect("empty nickname");
		Self(state)
	}
	/// Restore the directory serving this browser page without replacing any
	/// foreign routes or reviving an explicitly relinquished page directory.
	pub fn for_page_directory(
		&self,
		locator: &str,
		left: Option<&crate::text::DocumentText>,
		routes: &impl Routes,
	) -> Result<Self, Refusal> {
		let authority = routes.locator_authority(locator).ok_or(Refusal::Route)?;
		let mut state = self.0.clone();
		if left.is_some_and(|left| left.as_str() == Some(authority.as_str())) {
			return Ok(Self(state));
		}
		let address = fields::Id::new(locator.into()).ok_or(Refusal::Size)?;
		let id = fields::Id::new(authority.into()).ok_or(Refusal::Size)?;
		for directory in &mut state.directories.0 {
			directory.home = directory.id == id;
		}
		if let Some(directory) = state.directories.0.iter_mut().find(|directory| directory.id == id) {
			directory.locator = address;
		} else {
			let mut directories = state.directories.0;
			directories.push(model::Directory {
				id,
				locator: address,
				home: true,
				reached: Some(false),
				nick: fields::Field::new("".into()).expect("empty nickname"),
				nick_allocation: crate::directory::registration::NicknameAllocation::Exact,
				standing: fields::Nullable::Null,
			});
			state.directories = fields::List::new(directories).ok_or(Refusal::Size)?;
		}
		validate::state(&mut state, routes)?;
		Ok(Self(state))
	}
	pub fn decode(text: &str, routes: &impl Routes) -> Result<Self, Refusal> {
		if text.encode_utf16().take(MAX_CHECKPOINT_UNITS + 1).count() > MAX_CHECKPOINT_UNITS {
			return Err(Refusal::Size);
		}
		Self::decode_embedded(text, routes)
	}
	pub(crate) fn decode_embedded(text: &str, routes: &impl Routes) -> Result<Self, Refusal> {
		let mut state: model::State = crate::fields::json_object(text).map_err(|_| Refusal::Schema)?;
		validate::state(&mut state, routes)?;
		Ok(Self(state))
	}
	/// Serialize a borrowed projection. Neither the checkpoint nor its retained
	/// bearer strings are cloned while constructing an observing facet's view.
	pub fn without_authority(&self) -> impl serde::Serialize + '_ {
		projection::redacted(&self.0)
	}
	pub fn encode_for(&self, access: Access) -> Result<String, Refusal> {
		projection::encode(&self.0, access)
	}
}

// Durable envelopes serialize the validated graph directly, without an
// intermediate checkpoint JSON string. Facet projection still owns visibility.
impl serde::Serialize for Checkpoint {
	fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
		serde::Serialize::serialize(&self.0, s)
	}
}
