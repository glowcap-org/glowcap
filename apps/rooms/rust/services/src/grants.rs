//! Host filesystem specialization of shared grant execution.
pub type DurableGrants = rooms_runtime::grants::DurableGrants<crate::documents::DocumentFile>;
pub type LoadError = rooms_runtime::grants::LoadError<crate::documents::StorageError>;
