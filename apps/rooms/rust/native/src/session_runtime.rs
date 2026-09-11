//! Native session composition over shared directory and direct execution.
//! Room and direct message effects are shared; archives retain native storage.
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
pub use rooms::{typing, ConversationEvent, Events, Failure, FileCommand, RoomRuntime, RoomWorker};
#[cfg(test)]
mod tests;
use crate::client::Deadline;
pub use rooms_runtime::directory_runtime::{
	AcceptedDirect, Phase, RegistrationInbox, RegistrationWork, CONNECTING_LIMIT, REGISTRATION_BYTES,
	REGISTRATION_LIMIT,
};
pub type DirectoryRuntime = rooms_runtime::directory_runtime::DirectoryRuntime<Deadline>;
pub type DirectoryWorker = rooms_runtime::directory_runtime::DirectoryWorker<Deadline>;
pub type RuntimeEvents = rooms_runtime::directory_runtime::RuntimeEvents<Deadline>;
pub type Directories = rooms_runtime::directory_runtime::Directories<Deadline>;
pub type DirectoryRow = rooms_runtime::directory_runtime::DirectoryRow<Deadline>;
