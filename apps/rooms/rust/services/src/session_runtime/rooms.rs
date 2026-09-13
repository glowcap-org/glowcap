//! Host specialization of shared room membership and message execution.
pub use rooms_runtime::rooms::{ConversationEvent, Events, Failure, FileCommand, typing};
pub type RoomRuntime = rooms_runtime::rooms::RoomRuntime<rooms_platform::HostPlatform>;
pub type RoomWorker = rooms_runtime::rooms::RoomWorker<rooms_platform::HostPlatform>;
