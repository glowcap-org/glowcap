//! Native specialization of shared room-link admission.
pub type RoomLinkReceiver =
	rooms_runtime::directory_runtime::room_invitations::RoomLinkReceiver<crate::client::Deadline>;
