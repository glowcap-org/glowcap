//! Native specialization of shared room-offer receipt custody.
pub use rooms_runtime::room_offers::{Outcome, Outcomes, RECEIPT_BYTES, RECEIPT_LIMIT};
pub type RoomOffers = rooms_runtime::room_offers::RoomOffers<crate::client::Deadline>;
pub type OfferReceiver = rooms_runtime::room_offers::OfferReceiver<crate::client::Deadline>;
pub type OfferWorker = rooms_runtime::room_offers::OfferWorker<crate::client::Deadline>;
