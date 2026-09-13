//! Shared Rooms execution. Platform adapters supply storage, entropy, clocks,
//! and transport effects; this crate owns their application ordering.

pub mod cleanup;
pub mod clock;
pub mod documents;
pub mod entropy;
pub mod error;
pub mod platform;
pub mod wall_clock;

pub use error::{Error, Worker};

pub mod archive;
pub mod direct;
pub mod directories;
pub mod files;
pub mod grants;
pub mod rooms;
pub mod service;
pub mod session;
