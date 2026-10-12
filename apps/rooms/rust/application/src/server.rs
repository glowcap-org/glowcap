//! What a Rooms server hosts, above CapTP: the durable document that names
//! it and the rooms it keeps authority over, and the directory every member
//! reaches it through. The policy here decides. A native adapter spawns the
//! capabilities, tells the observers, and keeps the document on disk.
pub mod directory;
pub mod document;
pub mod effects;
pub mod history;
pub mod invitation;
pub mod irc;
pub mod links;
pub mod operations;
pub mod peering;
mod refusal;
pub mod rooms;
pub mod trace;

pub use effects::Release;
pub use refusal::Refusal;
