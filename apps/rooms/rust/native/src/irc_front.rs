//! Ordinary IRC clients over Rooms capabilities. Portable IRC presentation is
//! shared policy; this adapter owns listeners, clients, and socket effects.
mod channels;
mod client;
mod config;
mod direct;
mod inboxes;
mod names;
mod output;
mod peer;
mod transport;
pub use config::{Config, HELP};
pub use peer::{run, Ready};
