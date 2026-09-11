//! Typed live views carried by a shared-session snapshot. They describe remote
//! state; none of their identifiers grants local mutation authority.
use super::{Field, Id, List, Nullable, Presence, SafeInteger, Text};
use crate::session::fields::present;
use crate::{
	room::policy::{MembershipKind, RoomPolicy},
	text::DocumentText,
};
use serde::{Deserialize, Serialize};

pub const MAX_MEMBERS: usize = 512;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SeatPhase {
	Rooms,
	Connecting,
	Linked,
	Failed,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Seat {
	pub network: Text<32, true>,
	pub state: SeatPhase,
	pub nick: Text<32, true>,
	pub badge: Text<12, true>,
	pub said: Text<120, true>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Member {
	pub online: bool,
	pub away: Text<120>,
	#[serde(default, deserialize_with = "present", skip_serializing_if = "Option::is_none")]
	pub seat: Option<Seat>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Bridge {
	pub prefix: Text<12, true>,
	pub badge: Text<12, true>,
	pub said: Text<120, true>,
	pub scope: Text<64, true>,
}
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct RoomView {
	pub conversation_id: Id,
	pub membership_kind: MembershipKind,
	pub policy: RoomPolicy,
	pub members: List<(Text<32, true>, Member), MAX_MEMBERS>,
	#[serde(default, deserialize_with = "present", skip_serializing_if = "Option::is_none")]
	pub members_more: Option<bool>,
	pub topic: Nullable<Text<300>>,
	pub line_bytes: Nullable<SafeInteger<true>>,
	#[serde(default, skip_serializing_if = "Presence::missing")]
	pub bridge: Presence<Bridge>,
	#[serde(default, deserialize_with = "present", skip_serializing_if = "Option::is_none")]
	pub can_set_topic: Option<bool>,
	#[serde(default, deserialize_with = "present", skip_serializing_if = "Option::is_none")]
	pub can_moderate: Option<bool>,
}
pub use crate::directory::{Member as Peer, OriginProof, PublicationKind, RoomInfo};
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct DirectoryView {
	pub directory_id: Id,
	pub rooms: List<RoomInfo, 1024>,
	pub peers: List<Peer, 1024>,
	pub truncated: bool,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ShareStatus {
	Offered,
	Reading,
	Unavailable,
}
pub use crate::archive::ShareKind;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Custody {
	Live,
	Durable,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct ArchiveShare {
	pub id: Id,
	pub directory: Id,
	pub conversation_id: Id,
	pub from: Text<32, true>,
	pub status: ShareStatus,
	pub error: Field,
	pub kind: ShareKind,
	pub scope_conversation: Nullable<DocumentText>,
	pub custody: Custody,
	pub sturdyref: Field,
}
impl ArchiveShare {
	pub fn decode(raw: &str) -> Result<Self, super::Refusal> {
		if raw.encode_utf16().take(128 * 1024 + 1).count() > 128 * 1024 {
			return Err(super::Refusal::Budget);
		}
		crate::fields::json_object(raw).map_err(|_| super::Refusal::Json)
	}
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HandedRoom {
	pub id: Id,
	pub directory: Id,
	pub label: Field,
	pub from: Text<32, true>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Adoption {
	Available,
	Closed,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EffectPhase {
	Unresolved,
	Prepared,
	Completed,
	Applied,
}
impl EffectPhase {
	pub fn as_str(self) -> &'static str {
		match self {
			Self::Unresolved => "unresolved",
			Self::Prepared => "prepared",
			Self::Completed => "completed",
			Self::Applied => "applied",
		}
	}
	pub fn parse(value: &str) -> Option<Self> {
		match value {
			"unresolved" => Some(Self::Unresolved),
			"prepared" => Some(Self::Prepared),
			"completed" => Some(Self::Completed),
			"applied" => Some(Self::Applied),
			_ => None,
		}
	}
}

pub(super) struct VisibleRoom<'a>(pub &'a RoomView, pub bool);
impl Serialize for RoomView {
	fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
		VisibleRoom(self, true).serialize(s)
	}
}
impl Serialize for VisibleRoom<'_> {
	fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
		use serde::ser::SerializeStruct;
		let r = self.0;
		let can_set_topic = if self.1 { r.can_set_topic } else { Some(false) };
		let can_moderate = if self.1 { r.can_moderate } else { Some(false) };
		let fields = 6
			+ usize::from(r.members_more.is_some())
			+ usize::from(!r.bridge.missing())
			+ usize::from(can_set_topic.is_some())
			+ usize::from(can_moderate.is_some());
		let mut value = s.serialize_struct("RoomView", fields)?;
		value.serialize_field("conversationId", &r.conversation_id)?;
		value.serialize_field("membershipKind", &r.membership_kind)?;
		value.serialize_field("policy", &r.policy)?;
		value.serialize_field("members", &r.members)?;
		if let Some(v) = r.members_more {
			value.serialize_field("membersMore", &v)?;
		}
		value.serialize_field("topic", &r.topic)?;
		value.serialize_field("lineBytes", &r.line_bytes)?;
		if !r.bridge.missing() {
			value.serialize_field("bridge", &r.bridge)?;
		}
		if let Some(v) = can_set_topic {
			value.serialize_field("canSetTopic", &v)?;
		}
		if let Some(v) = can_moderate {
			value.serialize_field("canModerate", &v)?;
		}
		value.end()
	}
}
