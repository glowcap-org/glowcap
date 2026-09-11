//! Native specialization of shared direct execution.
use crate::client::Deadline;
pub use rooms_runtime::direct_routes::Adoption;
pub type DirectRoutes = rooms_runtime::direct_routes::DirectRoutes<Deadline>;
pub type RouteReceiver = rooms_runtime::direct_routes::RouteReceiver<Deadline>;
