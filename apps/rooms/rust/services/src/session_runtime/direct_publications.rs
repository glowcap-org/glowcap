//! Host specialization of shared direct execution.
use rooms_platform::HostPlatform;
pub use rooms_runtime::direct::publications::OFFER_LIMIT;
pub type DirectPublications = rooms_runtime::direct::publications::DirectPublications<HostPlatform>;
