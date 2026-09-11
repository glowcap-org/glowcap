//! Native scheduling specialization of shared directory connection execution.
use crate::client::Deadline;

pub use rooms_runtime::session_directory::{Event, Notice, Register};
pub type Source = rooms_runtime::session_directory::Source<Deadline>;
pub type DirectoryConnection = rooms_runtime::session_directory::DirectoryConnection<Deadline>;
pub type DirectoryState = rooms_runtime::session_directory::DirectoryState<Deadline>;
pub type DirectoryEvents = rooms_runtime::session_directory::DirectoryEvents<Deadline>;
pub type LiveDirectory = rooms_runtime::session_directory::LiveDirectory<Deadline>;

#[cfg(test)]
mod tests;
