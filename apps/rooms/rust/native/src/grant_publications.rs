//! Native filesystem specialization of shared grant publications.
pub use rooms_runtime::grant_publications::{GrantedBehavior, PublicationFailure};
pub type PublishedGrants = rooms_runtime::grant_publications::PublishedGrants<crate::documents::DocumentFile>;
pub type Error = rooms_runtime::grant_publications::Error<crate::documents::StorageError>;
#[cfg(test)]
mod tests;
