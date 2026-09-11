//! Native specialization of shared received-room custody.
pub use rooms_runtime::directory_runtime::handed_rooms::{
	Acceptance, ACCEPTANCE_BYTES, ACCEPTANCE_LIMIT, OBSERVER_LIMIT,
};
pub type HandedRooms = rooms_runtime::directory_runtime::handed_rooms::HandedRooms<crate::client::Deadline>;
pub type HandedReceiver = rooms_runtime::directory_runtime::handed_rooms::HandedReceiver<crate::client::Deadline>;
pub type HandedWorker = rooms_runtime::directory_runtime::handed_rooms::HandedWorker<crate::client::Deadline>;
