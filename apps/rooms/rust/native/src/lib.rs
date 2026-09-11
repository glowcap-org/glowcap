//! Native execution for Rooms application owners. Disk work stays off the
//! current-thread capability executor and retains its owner until completion.
#![forbid(unsafe_code)]
pub mod archive;
#[cfg(feature = "service")]
use rooms_runtime::cleanup;
#[cfg(feature = "service")]
pub mod chat;
pub mod client;
pub mod documents;
pub mod entropy;
pub mod grant_commands;
pub mod grant_publications;
pub mod grants;
#[cfg(feature = "service")]
pub mod irc;
#[cfg(feature = "service")]
pub mod irc_bridge;
#[cfg(feature = "service")]
pub mod irc_front;
pub mod media_files;
#[cfg(feature = "service")]
pub mod room_server;
#[cfg(feature = "service")]
pub mod serving;
mod storage;
#[cfg(feature = "service")]
mod tls;
#[cfg(feature = "service")]
pub mod web;
#[cfg(feature = "service")]
mod websocket;

pub mod session_archive;
pub use rooms_runtime::session_commands;
#[cfg(test)]
#[path = "session_commands/tests.rs"]
mod session_command_tests;
pub mod session_directory;
pub mod session_retention;
pub mod session_runtime;
#[cfg(feature = "service")]
pub mod session_service;
pub mod session_state;
