//! Host specialization of shared direct execution.
use rooms_platform::HostPlatform;
pub use rooms_runtime::direct::openings::{OPENING_LIMIT, WAITER_LIMIT};
pub type RouteOpenings = rooms_runtime::direct::openings::RouteOpenings<HostPlatform>;
pub type RouteWaiter = rooms_runtime::direct::openings::RouteWaiter<HostPlatform>;
pub type RequestedRoute = rooms_runtime::direct::openings::RequestedRoute<HostPlatform>;
