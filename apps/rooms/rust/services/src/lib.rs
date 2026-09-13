//! Rooms service composition over portable policy and explicit host effects.
pub mod archive;
#[cfg(feature = "processes")]
use rooms_runtime::cleanup;
#[cfg(feature = "processes")]
pub mod chat;
pub mod documents;
pub mod grant_commands;
pub mod grant_publications;
pub mod grants;
#[cfg(feature = "processes")]
pub mod irc;
#[cfg(feature = "processes")]
pub mod irc_bridge;
#[cfg(feature = "processes")]
pub mod irc_front;
pub mod media_files;
#[cfg(feature = "processes")]
pub mod server;
#[cfg(feature = "processes")]
pub mod web;

pub mod session_archive;
pub use rooms_runtime::session::commands as session_commands;
#[cfg(feature = "processes")]
pub mod session;
#[cfg(test)]
mod session_command_tests;
pub mod session_directory;
pub mod session_retention;
pub mod session_runtime;
pub mod session_state;
