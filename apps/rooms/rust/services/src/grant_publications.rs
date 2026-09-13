//! Host filesystem specialization of shared grant publications.
pub use rooms_runtime::grants::publications::{GrantedBehavior, PublicationFailure};
pub type PublishedGrants = rooms_runtime::grants::publications::PublishedGrants<crate::documents::DocumentFile>;
pub type Error = rooms_runtime::grants::publications::Error<crate::documents::StorageError>;
#[cfg(test)]
mod tests;
