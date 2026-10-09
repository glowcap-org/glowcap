//! Durable result data contains field coordinates, never bearer links. The
//! receipt separately owns the exact capability at each returned coordinate.
use super::custody::{FieldKey, Line, RoomAccess, RoomControl, RoomFiles, RoomSeat, RoomTopic};
use crate::{
	fields::SafeInteger,
	room::policy::RoomPolicy,
	server::operations::operator::view::rows::{Field, Name, Visibility},
};
use serde::{Deserialize, Serialize};

/// Identity and exact live name custody are acquired from one committed reply.
/// The ID is comparison data. Only the retained name can mint a voucher.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Registration {
	pub nick: crate::fields::Text<32, true>,
	pub id: crate::fields::Text<36, true>,
	pub name: FieldKey<super::custody::DirectoryName>,
}

/// The receipt owns the exact connection-lived lease. Acquisition confirms
/// lease creation; readiness is observed separately through that same lease.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Publication {
	pub lease: FieldKey<super::custody::PublicationLease>,
}

/// An accepted visit remains internal custody. Subscription consumes it through
/// the session executor, which mediates the returned membership capabilities.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Acceptance {
	pub entrance: FieldKey<super::custody::AcceptedAccess>,
}

/// An operations connection remains private custody. Later commands invoke it
/// under the original session dependency and the selected interface contract.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Connection {
	pub connection: FieldKey<super::custody::IrcConnection>,
}

/// A directory introduction either requests an inbox or returns its exact
/// registration-scoped custody. Pending is a known protocol answer, not an
/// uncertain transport outcome. A later attempt uses a new command identity.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "camelCase", deny_unknown_fields)]
pub enum Direct {
	Pending,
	Ready {
		inbox: FieldKey<super::custody::DirectAccess>,
	},
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Stewardship {
	pub name: Name,
	pub label: Field,
	pub visibility: Visibility,
	pub generation: SafeInteger,
	pub steward: Option<FieldKey<RoomAccess>>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RoomPolicyUpdate {
	pub name: crate::fields::Text<32, true>,
	pub policy: RoomPolicy,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RoomLink {
	pub room: FieldKey<RoomAccess>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RoomModerator {
	pub moderator: FieldKey<RoomAccess>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RoomManager {
	pub control: FieldKey<RoomControl>,
}

/// Independently issued room access and ownership, acquired from the exact
/// creation bootstrap. Each coordinate names its separate receipt occurrence.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ManagedRoom {
	pub room: FieldKey<RoomAccess>,
	pub control: FieldKey<RoomControl>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PostedLine {
	pub line: Option<FieldKey<Line>>,
	pub id: Option<SafeInteger>,
	pub history: Option<History>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct History {
	pub source: crate::fields::Text<{ crate::archive::MAX_ID_BYTES }, true>,
	pub generation: crate::fields::Text<{ crate::archive::MAX_ID_BYTES }, true>,
	pub id: crate::fields::Text<{ crate::archive::MAX_ID_BYTES }, true>,
}
impl History {
	pub fn from_coordinates(value: crate::archive::Coordinates) -> Option<Self> {
		Some(Self {
			source: crate::fields::Text::new(value.source)?,
			generation: crate::fields::Text::new(value.generation)?,
			id: crate::fields::Text::new(value.id)?,
		})
	}
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Membership {
	pub kind: crate::room::policy::MembershipKind,
	pub seat: FieldKey<RoomSeat>,
	pub topic: Option<FieldKey<RoomTopic>>,
	pub files: Option<FieldKey<RoomFiles>>,
}
