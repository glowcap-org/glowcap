//! Compatibility path for session-service callers. The error vocabulary is
//! owned by the runtime crate because owners below this layer return it too.
pub use crate::error::Error;
