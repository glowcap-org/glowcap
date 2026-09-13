//! Room authority identities and manager replies above the CapTP value layer.
use super::policy::RoomPolicy;
use alloc::string::String;
use sha2::{Digest, Sha256};

pub use crate::protocol_data::{GOVERNS, KICK, LINK, MANAGED_ROOM_IDENTITY as MANAGED_IDENTITY};
pub const GIVE_STEWARD: &str = "giveSteward";
pub const REVOKE_STEWARD: &str = "revokeSteward";
pub const REVOKE_ROOM_LINK: &str = "revokeRoomLink";
pub const UNREGISTER_ROOM: &str = "unregisterRoom";
pub const SET_POLICY: &str = "setRoomPolicy";
pub const REQUEST_TIMEOUT_MS: u64 = 15_000;

pub trait Reply {
	fn text(&self) -> Option<&str>;
	fn list_len(&self) -> Option<usize>;
	fn list_text(&self, index: usize) -> Option<&str>;
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
	Identity,
	ManagerMismatch,
	Link,
	Token,
	Policy,
	Steward,
	StewardMismatch,
}
impl core::fmt::Display for Refusal {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Steward => "the room did not answer with its steward authority",
			Self::StewardMismatch => "the room answered a steward for a different room authority",
			Self::Identity => "the room answered no management identity",
			Self::ManagerMismatch => "that room manager belongs to a different room",
			Self::Link => "the room manager named no room link",
			Self::Token => "a room authority sturdyref has no publication identity",
			Self::Policy => "the room manager answered an invalid or unsupported room policy",
		})
	}
}
impl core::error::Error for Refusal {}
pub fn management_identity(reply: &impl Reply) -> Result<&str, Refusal> {
	reply.text().filter(|v| !v.is_empty()).ok_or(Refusal::Identity)
}
pub fn verify_manager(governed: &impl Reply, identity: &impl Reply) -> Result<(), Refusal> {
	let identity = management_identity(identity)?;
	if governed.text() == Some(identity) {
		Ok(())
	} else {
		Err(Refusal::ManagerMismatch)
	}
}
pub fn room_link(reply: &impl Reply) -> Result<&str, Refusal> {
	reply.text().filter(|v| !v.is_empty()).ok_or(Refusal::Link)
}
pub fn verify_steward(governed: &impl Reply, room_token: &str) -> Result<(), Refusal> {
	let identity = room_identity(room_token)?;
	if governed.text() == Some(identity.as_str()) {
		Ok(())
	} else {
		Err(Refusal::StewardMismatch)
	}
}
pub struct PolicyUpdate<'a> {
	pub name: &'a str,
	pub policy: RoomPolicy,
}
pub fn policy_update(reply: &impl Reply) -> Result<PolicyUpdate<'_>, Refusal> {
	if reply.list_len() != Some(4) {
		return Err(Refusal::Policy);
	}
	let name = reply.list_text(0).filter(|v| !v.is_empty()).ok_or(Refusal::Policy)?;
	let modes = [reply.list_text(1), reply.list_text(2), reply.list_text(3)];
	let [Some(visibility), Some(entry), Some(speaking)] = modes else {
		return Err(Refusal::Policy);
	};
	let policy = RoomPolicy::parse(&[visibility, entry, speaking]).ok_or(Refusal::Policy)?;
	Ok(PolicyUpdate { name, policy })
}
/// A correlator for a room publication, never authority to enter it. The
/// caller's existing sturdyref parser supplies a nonempty decoded UTF-8 token.
pub fn room_identity(token: &str) -> Result<String, Refusal> {
	if token.is_empty() {
		return Err(Refusal::Token);
	}
	let mut hash = Sha256::new();
	hash.update(b"glowcap.rooms.room-authority\0");
	hash.update(token.as_bytes());
	let bytes = hash.finalize();
	Ok(crate::fields::lower_hex(&bytes))
}

pub struct StewardGrant<'a> {
	pub room_link: &'a str,
	pub room_identity: &'a str,
	pub steward_link: &'a str,
}
pub fn steward_grant(reply: &impl Reply) -> Result<StewardGrant<'_>, Refusal> {
	let field = |at| reply.list_text(at).filter(|v| !v.is_empty()).ok_or(Refusal::Steward);
	Ok(StewardGrant {
		room_link: field(0)?,
		room_identity: field(1)?,
		steward_link: field(2)?,
	})
}
impl StewardGrant<'_> {
	pub fn verify(&self, room_token: &str) -> Result<(), Refusal> {
		if room_identity(room_token)? == self.room_identity {
			Ok(())
		} else {
			Err(Refusal::StewardMismatch)
		}
	}
}
