//! Portable Rooms application policy. Platform adapters own I/O and acknowledge
//! durable writes before committing the corresponding application transition.
#![no_std]

extern crate alloc;

pub mod admission;
pub mod bridge;
pub mod content;
pub mod directory;
pub mod documents;
pub mod failure;
pub mod fields;
pub mod files;
pub mod grants;
pub mod ice;
pub mod markdown;
pub mod open_graph;
pub mod protocol_data;
pub mod room;
pub mod server;
pub mod session;
pub mod text;
pub mod web_channel;
pub mod web_relay;
pub mod workspace;

pub mod signaling;
pub mod slash;

pub mod archive;
pub mod direct;
