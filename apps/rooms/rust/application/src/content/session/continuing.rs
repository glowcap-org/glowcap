//! Closed methods for an owner's private continuation channel. The caller
//! must also present the exact root witness. A tag only names the verb. The
//! grant the call travels through still admits it.
#[derive(Clone, Copy)]
#[repr(i64)]
pub enum Method {
	Snapshot = 1,
	CheckInbox = 2,
	CheckDiscovery = 3,
	AcquireWorkspace = 4,
	RoomInvitationRecipe = 5,
	RetainRoomInvitation = 6,
	AcceptRoomInvitation = 7,
}
impl Method {
	pub const fn wire(self) -> i64 {
		self as i64
	}
	pub fn read(value: i64) -> Option<Self> {
		match value {
			1 => Some(Self::Snapshot),
			2 => Some(Self::CheckInbox),
			3 => Some(Self::CheckDiscovery),
			4 => Some(Self::AcquireWorkspace),
			5 => Some(Self::RoomInvitationRecipe),
			6 => Some(Self::RetainRoomInvitation),
			7 => Some(Self::AcceptRoomInvitation),
			_ => None,
		}
	}
	pub const fn verb(self) -> &'static str {
		match self {
			Self::Snapshot => "snapshot",
			Self::CheckInbox => "check-inbox",
			Self::CheckDiscovery => "check-discovery",
			Self::AcquireWorkspace => "acquire-workspace",
			Self::RoomInvitationRecipe => "activity-recipe",
			Self::RetainRoomInvitation => "retain-incoming",
			Self::AcceptRoomInvitation => "acquire-activity",
		}
	}
}
