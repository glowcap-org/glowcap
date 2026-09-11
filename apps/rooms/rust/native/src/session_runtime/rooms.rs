//! Native specialization of shared room membership and message execution.
pub use rooms_runtime::rooms::{typing, ConversationEvent, Events, Failure, FileCommand};
pub type RoomRuntime = rooms_runtime::rooms::RoomRuntime<crate::client::Deadline>;
pub type RoomWorker = rooms_runtime::rooms::RoomWorker<crate::client::Deadline>;
