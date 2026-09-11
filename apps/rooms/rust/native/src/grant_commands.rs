//! Shared grant command admission and execution over native documents.
pub use rooms_runtime::grant_commands::{
	grant_views, GrantCommandEffects, GrantCommands, GrantNotice, MAX_PENDING_GRANT_COMMANDS,
};
pub type GrantCommandWorker = rooms_runtime::grant_commands::GrantCommandWorker<crate::documents::DocumentFile>;
#[cfg(test)]
mod tests;
