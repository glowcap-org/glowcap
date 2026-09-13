//! Host specialization of shared room-offer receipt custody.
pub use rooms_runtime::rooms::offers::{Outcome, Outcomes, RECEIPT_BYTES, RECEIPT_LIMIT};
pub type RoomOffers = rooms_runtime::rooms::offers::RoomOffers<rooms_platform::HostPlatform>;
pub type OfferReceiver = rooms_runtime::rooms::offers::OfferReceiver<rooms_platform::HostPlatform>;
pub type OfferWorker = rooms_runtime::rooms::offers::OfferWorker<rooms_platform::HostPlatform>;
