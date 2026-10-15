//! Room publications and registered members carried by directory discovery.
use crate::{
	fields::{Nullable, SafeInteger, Text},
	room::policy::MembershipKind,
	text::DocumentText,
};
use serde::{Deserialize, Serialize};
/// Where a publication comes from. The order is the order a directory lists
/// in: its own rooms, then the foreign ones, then the bridged channels.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PublicationKind {
	Local,
	Foreign,
	Bridge,
}
impl PublicationKind {
	pub const fn wire(self) -> &'static str {
		match self {
			Self::Local => "local",
			Self::Foreign => "foreign",
			Self::Bridge => "bridge",
		}
	}
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OriginProof {
	Local,
	Authenticated,
	Session,
	Bridge,
}
impl OriginProof {
	pub const fn wire(self) -> &'static str {
		match self {
			Self::Local => "local",
			Self::Authenticated => "authenticated",
			Self::Session => "session",
			Self::Bridge => "bridge",
		}
	}
}
/// Longest publication id, in bytes.
pub const MAX_PUBLICATION_ID: usize = 128;
/// Longest publication origin, in bytes.
pub const MAX_ORIGIN: usize = 256;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RoomInfo {
	pub id: Text<MAX_PUBLICATION_ID, true>,
	pub name: Text<32, true>,
	pub kind: PublicationKind,
	pub count: Nullable<SafeInteger>,
	pub origin: Text<MAX_ORIGIN>,
	pub proof: OriginProof,
	pub offers: Nullable<MembershipKind>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Member {
	pub name: Text<32, true>,
	pub registration_id: DocumentText,
}
impl RoomInfo {
	pub fn valid(&self) -> bool {
		let empty = self.origin.text().utf16().next().is_none();
		match self.kind {
			PublicationKind::Local => self.count.as_ref().is_some() && empty && self.proof == OriginProof::Local,
			PublicationKind::Foreign => self.count.as_ref().is_none() && !empty && self.proof != OriginProof::Local,
			PublicationKind::Bridge => !empty && self.proof == OriginProof::Bridge,
		}
	}
}
