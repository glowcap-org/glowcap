//! Host specialization of shared direct execution.
use rooms_platform::HostPlatform;
pub use rooms_runtime::direct::dispatch::{Effect, OPERATION_LIMIT, Outcome, Outcomes, REQUEST_LIMIT};
pub type DirectDispatcher = rooms_runtime::direct::dispatch::DirectDispatcher<HostPlatform>;
pub type Opening = rooms_runtime::direct::dispatch::Opening<HostPlatform>;
pub type DirectWorker = rooms_runtime::direct::dispatch::DirectWorker<HostPlatform>;
