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
pub mod files;
pub mod session;
pub mod trace;
