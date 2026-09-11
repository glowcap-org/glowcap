//! IRC transport ownership shared by network feeds and member identities.
//! Application state stays in rooms_application::server::irc; this adapter
//! owns sockets, TLS, bounded writes, deadlines and cancellation.
mod connection;
pub mod feed;
pub mod member;
pub(crate) mod socket;
mod tls;
pub use connection::{Connection, Event, Events, Worker};
pub use socket::{Delivery, WriteError, WriteReceipt};
pub use tls::{Endpoint, Tls};

#[cfg(test)]
mod tests;
