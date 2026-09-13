//! Host scheduling specialization of shared directory connection execution.
use rooms_platform::HostPlatform;

pub use rooms_runtime::directories::session::{Event, Notice, Register};
pub type Source = rooms_runtime::directories::session::Source<HostPlatform>;
pub type DirectoryConnection = rooms_runtime::directories::session::DirectoryConnection<HostPlatform>;
pub type DirectoryState = rooms_runtime::directories::session::DirectoryState<HostPlatform>;
pub type DirectoryEvents = rooms_runtime::directories::session::DirectoryEvents<HostPlatform>;
pub type LiveDirectory = rooms_runtime::directories::session::LiveDirectory<HostPlatform>;

#[cfg(test)]
mod tests;
