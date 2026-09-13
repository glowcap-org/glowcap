//! Host session composition over shared directory and direct execution.
//! Room and direct message effects are shared; archives retain host storage.
pub mod archive_shares;
pub mod direct_commands;
pub mod direct_dispatch;
pub mod direct_events;
pub mod direct_outgoing;
pub mod direct_publications;
pub mod direct_routes;
pub mod handed_rooms;
pub mod operations;
pub mod peering;
pub mod room_invitations;
pub mod room_offers;
mod rooms;
pub mod route_openings;
pub use rooms::{ConversationEvent, Events, Failure, FileCommand, RoomRuntime, RoomWorker, typing};
#[cfg(test)]
mod tests;
use rooms_platform::HostPlatform;
pub use rooms_runtime::directories::runtime::{
	AcceptedDirect, CONNECTING_LIMIT, Phase, REGISTRATION_BYTES, REGISTRATION_LIMIT, RegistrationInbox,
	RegistrationWork,
};
pub type DirectoryRuntime = rooms_runtime::directories::runtime::DirectoryRuntime<HostPlatform>;
pub type DirectoryWorker = rooms_runtime::directories::runtime::DirectoryWorker<HostPlatform>;
pub type RuntimeEvents = rooms_runtime::directories::runtime::RuntimeEvents<HostPlatform>;
pub type Directories = rooms_runtime::directories::runtime::Directories<HostPlatform>;
pub type DirectoryRow = rooms_runtime::directories::runtime::DirectoryRow<HostPlatform>;
