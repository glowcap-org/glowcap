//! What a Rooms server hosts, above CapTP: the durable document that names
//! it and the rooms it keeps authority over, and the directory every member
//! reaches it through. The policy here decides; a native adapter spawns the
//! capabilities, tells the observers, and keeps the document on disk.
pub mod directory;
pub mod document;
pub mod history;
pub mod invitation;
pub mod irc;
pub mod links;
pub mod operations;
pub mod peering;
pub mod rooms;
pub mod viz;
