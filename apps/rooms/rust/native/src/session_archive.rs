//! Native archive composition; shared execution owns admission and retained views.
pub use rooms_runtime::session_archive::{FileRecording, MetadataReason, Recorded, Recording, Reply, Report};
pub type SessionArchive = rooms_runtime::session_archive::SessionArchive<crate::client::Deadline>;
pub type Worker<B> = rooms_runtime::session_archive::Worker<B, crate::client::Deadline>;
pub type ArchivedBlob = rooms_runtime::session_archive::ArchivedBlob<crate::client::Deadline>;
pub type LocalBlob = rooms_runtime::session_archive::LocalBlob<crate::client::Deadline>;
pub type Blob = rooms_runtime::session_archive::Blob<crate::client::Deadline>;
pub type Keeper = rooms_runtime::session_archive::Keeper<crate::client::Deadline>;
pub type KeptRecord = rooms_runtime::session_archive::KeptRecord<crate::client::Deadline>;
pub type Local = rooms_runtime::session_archive::Local<crate::client::Deadline>;
pub type Peer = rooms_runtime::session_archive::Peer<crate::client::Deadline>;

#[cfg(all(test, feature = "service"))]
mod file_tests;
#[cfg(test)]
mod tests;

#[cfg(test)]
use crate::{archive::Backend, client::Deadline};
#[cfg(test)]
use glowcap::Runtime;
#[cfg(test)]
use rooms_application::archive::{index::Page, Filter, Record};
#[cfg(test)]
use rooms_glowcap::client::files::File;
#[cfg(test)]
use rooms_runtime::session_archive::{MAX_BYTES, MAX_PENDING};
#[cfg(test)]
use std::{cell::Cell, rc::Rc};
