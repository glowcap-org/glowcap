//! Host specialization of shared direct message admission and event custody.
use rooms_platform::HostPlatform;
pub use rooms_runtime::direct::events::{
	Content, Direction, EVENT_BYTES, EVENT_LIMIT, Event, Events, Line, Reservation,
};
pub type DirectEvents = rooms_runtime::direct::events::DirectEvents<HostPlatform>;
pub type EventReceiver = rooms_runtime::direct::events::EventReceiver<HostPlatform>;
