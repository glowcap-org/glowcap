//! Host specialization of shared direct execution.
use rooms_platform::HostPlatform;
pub use rooms_runtime::direct::routes::Adoption;
pub type DirectRoutes = rooms_runtime::direct::routes::DirectRoutes<HostPlatform>;
pub type RouteReceiver = rooms_runtime::direct::routes::RouteReceiver<HostPlatform>;
