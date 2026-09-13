//! Shared grant command admission and execution over host documents.
pub use rooms_runtime::grants::commands::{
	GrantCommandEffects, GrantCommands, GrantNotice, MAX_PENDING_GRANT_COMMANDS, grant_views,
};
pub type GrantCommandWorker = rooms_runtime::grants::commands::GrantCommandWorker<crate::documents::DocumentFile>;
#[cfg(test)]
mod tests;
