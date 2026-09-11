//! Native specialization of shared direct execution.
use crate::client::Deadline;
pub use rooms_runtime::direct_dispatch::{Effect, Outcome, Outcomes, OPERATION_LIMIT, REQUEST_LIMIT};
pub type DirectDispatcher = rooms_runtime::direct_dispatch::DirectDispatcher<Deadline>;
pub type Opening = rooms_runtime::direct_dispatch::Opening<Deadline>;
pub type DirectWorker = rooms_runtime::direct_dispatch::DirectWorker<Deadline>;
