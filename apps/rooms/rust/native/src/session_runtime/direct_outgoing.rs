//! Native specialization of shared direct delivery and media custody.
use crate::client::Deadline;
pub use rooms_runtime::direct_outgoing::{Delivery, Failure, Sending, Sent, LINE_LIMIT, OPERATION_LIMIT};
pub type DirectOutgoing = rooms_runtime::direct_outgoing::DirectOutgoing<Deadline>;
pub type OutgoingWorker = rooms_runtime::direct_outgoing::OutgoingWorker<Deadline>;
