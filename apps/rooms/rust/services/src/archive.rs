//! Host archive composition. Shared execution owns capability admission and
//! backend ordering. This adapter owns filesystem storage and the process front.
pub use rooms_runtime::archive::{
	Backend, BlobAccess, CALLER_LIMIT, CAPTURE_BYTES, CAPTURE_LIMIT, Chunk, FACET_BYTES, REQUEST_BYTES, REQUEST_LIMIT,
	Report, Source, UnavailableBlobs,
};
pub type Archive = rooms_runtime::archive::Archive<rooms_platform::HostPlatform>;
pub type Receiver = rooms_runtime::archive::Receiver<rooms_platform::HostPlatform>;
pub type Worker<B> = rooms_runtime::archive::Worker<B, rooms_platform::HostPlatform>;
pub mod file;
#[cfg(feature = "processes")]
pub mod peer;
#[cfg(test)]
mod tests;
