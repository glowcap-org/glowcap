//! Rooms service composition over portable policy and explicit host effects.
pub mod archive;
#[cfg(feature = "processes")]
use rooms_runtime::cleanup;
#[cfg(feature = "processes")]
pub mod chat;
pub mod documents;
#[cfg(feature = "processes")]
pub mod irc;
#[cfg(feature = "processes")]
pub mod irc_bridge;
#[cfg(feature = "processes")]
pub mod irc_server;
pub mod media_files;
#[cfg(feature = "processes")]
pub mod server;
#[cfg(feature = "processes")]
pub mod trace_view;
#[cfg(feature = "processes")]
pub mod web;

#[cfg(feature = "processes")]
pub mod session;
pub mod session_archive;
