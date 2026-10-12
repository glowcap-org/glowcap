//! Closed methods for an owner's private continuation channel. The caller
//! must also present the exact root witness. These tags grant no authority.
#[derive(Clone, Copy)]
#[repr(i64)]
pub enum Method {
	Snapshot = 1,
	CheckInbox = 2,
	CheckDiscovery = 3,
	AcquireWorkspace = 4,
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
			_ => None,
		}
	}
	pub const fn verb(self) -> &'static str {
		match self {
			Self::Snapshot => "snapshot",
			Self::CheckInbox => "check-inbox",
			Self::CheckDiscovery => "check-discovery",
			Self::AcquireWorkspace => "acquire-workspace",
		}
	}
}
