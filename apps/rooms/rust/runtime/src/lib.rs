//! Shared Rooms execution. Platform adapters supply storage, entropy, clocks,
//! and transport effects; this crate owns their application ordering.
#![forbid(unsafe_code)]

pub mod cleanup;
pub mod clock;
pub mod connections;
pub mod directory_runtime;
pub mod documents;
pub mod entropy;
pub mod session_commands;
pub mod session_state;

pub mod session_directory;

pub mod direct_dispatch;
pub mod direct_publications;
pub mod direct_routes;
pub mod route_openings;

pub mod media;
pub mod media_files;

pub mod archive_recording;
pub mod bridge_secrets;
pub mod wall_clock;

pub mod direct_events;

pub mod command_files;
pub mod direct_commands;
pub mod direct_outgoing;

pub mod platform;
pub mod rooms;

pub mod archive;
pub mod session_archive;

pub mod archive_shares;
pub mod operations;
pub mod peering;
pub mod room_offers;

pub mod session_projection;

pub mod grant_commands;
pub mod grant_publications;
pub mod grants;

pub mod session_service;

pub mod session_retention;
