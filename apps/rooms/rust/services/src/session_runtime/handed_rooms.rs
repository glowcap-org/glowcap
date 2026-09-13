//! Host specialization of shared received-room custody.
pub use rooms_runtime::directories::runtime::handed_rooms::{
	ACCEPTANCE_BYTES, ACCEPTANCE_LIMIT, Acceptance, OBSERVER_LIMIT,
};
pub type HandedRooms = rooms_runtime::directories::runtime::handed_rooms::HandedRooms<rooms_platform::HostPlatform>;
pub type HandedReceiver =
	rooms_runtime::directories::runtime::handed_rooms::HandedReceiver<rooms_platform::HostPlatform>;
pub type HandedWorker = rooms_runtime::directories::runtime::handed_rooms::HandedWorker<rooms_platform::HostPlatform>;
