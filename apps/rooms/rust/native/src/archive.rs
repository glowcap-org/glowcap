//! Native archive composition. Shared execution owns capability admission and
//! backend ordering; this adapter owns filesystem storage and the process front.
pub use rooms_runtime::archive::{
	Backend, BlobAccess, Chunk, Report, Source, UnavailableBlobs, CALLER_LIMIT, CAPTURE_BYTES, CAPTURE_LIMIT,
	FACET_BYTES, REQUEST_BYTES, REQUEST_LIMIT,
};
pub type Archive = rooms_runtime::archive::Archive<crate::client::Deadline>;
pub type Receiver = rooms_runtime::archive::Receiver<crate::client::Deadline>;
pub type Worker<B> = rooms_runtime::archive::Worker<B, crate::client::Deadline>;
pub mod file;
#[cfg(feature = "service")]
pub mod service;
#[cfg(test)]
mod tests;
