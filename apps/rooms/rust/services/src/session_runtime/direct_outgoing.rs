//! Host specialization of shared direct delivery and media custody.
use rooms_platform::HostPlatform;
pub use rooms_runtime::direct::outgoing::{Delivery, Failure, LINE_LIMIT, OPERATION_LIMIT, Sending, Sent};
pub type DirectOutgoing = rooms_runtime::direct::outgoing::DirectOutgoing<HostPlatform>;
pub type OutgoingWorker = rooms_runtime::direct::outgoing::OutgoingWorker<HostPlatform>;
