//! Host specialization of shared room-link admission.
pub type RoomLinkReceiver =
	rooms_runtime::directories::runtime::room_invitations::RoomLinkReceiver<rooms_platform::HostPlatform>;
