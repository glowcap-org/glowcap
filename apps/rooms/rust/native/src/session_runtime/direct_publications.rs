//! Native specialization of shared direct execution.
use crate::client::Deadline;
pub use rooms_runtime::direct_publications::OFFER_LIMIT;
pub type DirectPublications = rooms_runtime::direct_publications::DirectPublications<Deadline>;
