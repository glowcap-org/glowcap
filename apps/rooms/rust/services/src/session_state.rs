//! Host storage and entropy specialization of the shared session owner.
pub use rooms_runtime::session::state::{
	LoadStatus, OrdinaryStatus, RecordedStatus, ResultStatus, SessionView, ViewError,
};
pub type Error = rooms_runtime::session::state::Error<crate::documents::StorageError>;
pub type DurableSession =
	rooms_runtime::session::state::DurableSession<crate::documents::StateDocuments, rooms_platform::OsEntropy>;
#[cfg(test)]
mod tests;
