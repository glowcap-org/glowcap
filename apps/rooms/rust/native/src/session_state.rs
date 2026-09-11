//! Native storage and entropy specialization of the shared session owner.
pub use rooms_runtime::session_state::{
	LoadStatus, OrdinaryStatus, RecordedStatus, ResultStatus, SessionView, ViewError,
};
pub type Error = rooms_runtime::session_state::Error<crate::documents::StorageError>;
pub type DurableSession =
	rooms_runtime::session_state::DurableSession<crate::documents::StateDocuments, crate::entropy::OsEntropy>;
#[cfg(test)]
mod tests;
