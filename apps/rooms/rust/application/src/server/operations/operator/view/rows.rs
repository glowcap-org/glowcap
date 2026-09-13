//! Admitted operator rows, shared by direct and attached consumers. Inventory
//! construction stays with the server; these values own bounded display data.
pub use super::super::{ReferenceKind, rows::RoomKind};
use crate::fields::{List, Nullable, Object, SafeInteger, Text};
pub use crate::server::operations::faces::Visibility;
use serde::{Deserialize, Serialize};
pub type Field = Text<65536>;
pub type Name = Text<65536, true>;
pub type Rows<T> = List<Object<T>, { super::super::MAX_PAGE as usize }>;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Stewardship {
	pub name: Name,
	pub label: Field,
	pub visibility: Visibility,
	pub generation: SafeInteger,
	pub issued: bool,
	pub steward: Nullable<Field>,
}
impl Stewardship {
	pub(super) fn validate(&self) -> Result<(), super::Refusal> {
		match (&self.steward, self.issued) {
			(Nullable::Null, false) => Ok(()),
			(Nullable::Value(link), true) if link.text().utf16().next().is_some() => Ok(()),
			_ => Err(super::Refusal::Relation),
		}
	}
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Link {
	pub name: Name,
	pub label: Field,
	pub visibility: Visibility,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Registration {
	pub nick: Field,
	pub session_id: Field,
	pub you: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Session {
	pub id: Field,
	pub transport: Field,
	pub nick: Field,
	pub you: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Room {
	pub id: Field,
	pub kind: RoomKind,
	pub name: Field,
	pub origin: Field,
	pub proof: Proof,
	pub retained_capabilities: Nullable<SafeInteger>,
	pub members: Rows<Member>,
	pub members_more: bool,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Proof {
	Local,
	Authenticated,
	Session,
	Bridge,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Member {
	pub nick: Field,
	pub session_id: Field,
	pub state: Field,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Reference {
	pub id: Name,
	pub kind: ReferenceKind,
	pub owner: Name,
	pub room: Field,
	pub member: Field,
	pub detail: Name,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Trouble {
	pub source: Text<{ crate::server::operations::journal::MAX_SOURCE_BYTES }>,
	pub reason: Text<{ crate::server::operations::journal::MAX_REASON_BYTES }>,
	pub count: SafeInteger<true>,
}
