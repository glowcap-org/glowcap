//! Native specialization of shared direct execution.
use crate::client::Deadline;
pub use rooms_runtime::route_openings::{OPENING_LIMIT, WAITER_LIMIT};
pub type RouteOpenings = rooms_runtime::route_openings::RouteOpenings<Deadline>;
pub type RouteWaiter = rooms_runtime::route_openings::RouteWaiter<Deadline>;
pub type RequestedRoute = rooms_runtime::route_openings::RequestedRoute<Deadline>;
