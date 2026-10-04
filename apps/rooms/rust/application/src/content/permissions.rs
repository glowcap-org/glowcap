//! Stable Rooms permission keys and application validation, without policy
//! intersection, scope evaluation or a second grant ledger.
use serde::{Deserialize, Serialize};
pub const IDENTITY: [u8; 16] = *b"rooms-policy-v01";

macro_rules! permissions {
	($($name:ident = $key:literal => $wire:literal, $needs:expr;)*) => {
		#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
		#[repr(u64)]
		pub enum Permission {
			$(#[serde(rename = $wire)] $name = $key,)*
		}
		impl Permission {
			pub const ALL: &'static [Self] = &[$(Self::$name,)*];
			pub const fn key(self) -> u64 { self as u64 }
			pub const fn from_key(key: u64) -> Option<Self> { match key { $($key => Some(Self::$name),)* _ => None } }
			pub const fn name(self) -> &'static str { match self { $(Self::$name => $wire,)* } }
			pub const fn prerequisite(self) -> Option<Self> { match self { $(Self::$name => $needs,)* } }
		}
	};
}
// Keys are explicit: editing declaration order cannot reinterpret saved terms.
permissions! {
	Browse = 1 => "browse", None;
	Presence = 2 => "presence", None;
	Introduce = 3 => "introduce", Some(Self::Presence);
	Signal = 4 => "signal", Some(Self::Presence);
	CreateRoom = 5 => "createRoom", None;
	PublishListing = 6 => "publishListing", None;
	Receive = 7 => "receive", None;
	History = 8 => "history", None;
	Post = 9 => "post", Some(Self::Receive);
	EditOwn = 10 => "editOwn", Some(Self::Receive);
	WithdrawOwn = 11 => "withdrawOwn", Some(Self::Receive);
	ReadContent = 12 => "readContent", None;
	ReadFile = 13 => "readFile", None;
	Upload = 14 => "upload", Some(Self::Post);
	SetTopic = 15 => "setTopic", Some(Self::Receive);
	Invite = 16 => "invite", None;
	Moderate = 17 => "moderate", None;
	ListEntries = 18 => "listEntries", None;
	CreateChild = 19 => "createChild", None;
	Rename = 20 => "rename", None;
	Reorganize = 21 => "reorganize", None;
	ArchiveConversation = 22 => "archiveConversation", None;
	EditContent = 23 => "editContent", None;
	WithdrawContent = 24 => "withdrawContent", None;
	ObserveWorkspace = 25 => "observeWorkspace", None;
	InteractWorkspace = 26 => "interactWorkspace", Some(Self::ObserveWorkspace);
	ReplaceWorkspace = 27 => "replaceWorkspace", Some(Self::ObserveWorkspace);
	ManageCustody = 28 => "manageCustody", Some(Self::ObserveWorkspace);
	ResolvePending = 29 => "resolvePending", Some(Self::ObserveWorkspace);
	UseOperations = 30 => "useOperations", Some(Self::ObserveWorkspace);
	RecordArchive = 31 => "recordArchive", None;
	ReadArchive = 32 => "readArchive", None;
	ManagePublicOffer = 33 => "managePublicOffer", None;
	ManagePublication = 34 => "managePublication", None;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InvalidPolicy {
	Inapplicable(Permission),
	Duplicate(Permission),
	Prerequisite {
		permission: Permission,
		required: Permission,
	},
}
impl core::fmt::Display for InvalidPolicy {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		write!(f, "invalid Rooms policy: {self:?}")
	}
}
impl core::error::Error for InvalidPolicy {}

/// Application dependencies and interface support only. Shared Zig must still
/// validate descriptor identity, scope, constraints, ceilings and source state.
pub fn validate(values: &[Permission], supported: &[Permission]) -> Result<(), InvalidPolicy> {
	for (index, &permission) in values.iter().enumerate() {
		if !supported.contains(&permission) {
			return Err(InvalidPolicy::Inapplicable(permission));
		}
		if values[..index].contains(&permission) {
			return Err(InvalidPolicy::Duplicate(permission));
		}
		if let Some(required) = permission.prerequisite()
			&& !values.contains(&required)
		{
			return Err(InvalidPolicy::Prerequisite { permission, required });
		}
	}
	Ok(())
}
