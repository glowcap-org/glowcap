//! Host archive composition. Shared execution owns admission and retained views.
pub use rooms_runtime::archive::session::{FileRecording, MetadataReason, Recorded, Recording, Reply, Report};
pub type SessionArchive = rooms_runtime::archive::session::SessionArchive<rooms_platform::HostPlatform>;
pub type Worker<B> = rooms_runtime::archive::session::Worker<B, rooms_platform::HostPlatform>;
pub type ArchivedBlob = rooms_runtime::archive::session::ArchivedBlob<rooms_platform::HostPlatform>;
pub type LocalBlob = rooms_runtime::archive::session::LocalBlob<rooms_platform::HostPlatform>;
pub type Blob = rooms_runtime::archive::session::Blob<rooms_platform::HostPlatform>;
pub type Keeper = rooms_runtime::archive::session::Keeper<rooms_platform::HostPlatform>;
pub type KeptRecord = rooms_runtime::archive::session::KeptRecord<rooms_platform::HostPlatform>;
pub type Local = rooms_runtime::archive::session::Local<rooms_platform::HostPlatform>;
pub type Peer = rooms_runtime::archive::session::Peer<rooms_platform::HostPlatform>;

#[cfg(test)]
#[cfg(feature = "processes")]
mod file_tests;
#[cfg(test)]
mod tests;

#[cfg(test)]
use crate::archive::Backend;
#[cfg(test)]
use glowcap::Runtime;
#[cfg(test)]
use rooms_application::archive::{Filter, Record, index::Page};
#[cfg(test)]
use rooms_glowcap::client::files::File;
#[cfg(test)]
use rooms_platform::HostPlatform;
#[cfg(test)]
use rooms_runtime::archive::session::{MAX_BYTES, MAX_PENDING};
#[cfg(test)]
use std::{cell::Cell, rc::Rc};
