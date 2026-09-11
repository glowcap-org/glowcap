//! Native specialization of shared direct message admission and event custody.
use crate::client::Deadline;
pub use rooms_runtime::direct_events::{
	Content, Direction, Event, Events, Line, Reservation, EVENT_BYTES, EVENT_LIMIT,
};
pub type DirectEvents = rooms_runtime::direct_events::DirectEvents<Deadline>;
pub type EventReceiver = rooms_runtime::direct_events::EventReceiver<Deadline>;
