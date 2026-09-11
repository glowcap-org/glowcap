//! The standalone IRC bridge executable: one channel, one shared IRC identity,
//! and a Rooms directory. Socket ownership stays in the native IRC adapter.
mod behavior;
mod config;
mod feed;
mod outbound;
mod peer;
mod state;
pub use config::{Config, HELP};
pub use peer::{run, Ready};
