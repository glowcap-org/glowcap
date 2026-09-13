//! The standalone IRC bridge executable: one channel, one shared IRC identity,
//! and a Rooms directory. Socket ownership stays in the host IRC adapter.
mod behavior;
mod config;
mod feed;
mod notice;
mod outbound;
mod peer;
mod state;
pub use config::{Config, HELP};
pub use notice::{Notice, Report};
pub use peer::{Ready, run};
