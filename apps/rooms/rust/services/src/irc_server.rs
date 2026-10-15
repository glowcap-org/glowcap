//! Ordinary IRC clients over Rooms capabilities. Portable IRC presentation is
//! shared policy. This adapter owns listeners, clients, and socket effects.
mod channels;
mod client;
mod config;
mod direct;
mod failure;
mod inboxes;
mod names;
mod notice;
mod output;
mod peer;
mod transport;
pub use config::{Config, HELP};
pub use notice::{Notice, Report};
pub use peer::{Ready, run};
