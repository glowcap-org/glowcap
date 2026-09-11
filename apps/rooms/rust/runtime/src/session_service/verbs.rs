//! The facet's verbs, one module per subject. Each takes the facet, the
//! caller's rights, and the delivered arguments, and returns a typed outcome;
//! the facet's dispatch table is the only place a verb name is matched.
pub mod archive_shares;
pub mod attachments;
pub mod bridge;
pub mod checkpoint;
pub mod command;
pub mod delegation;
pub mod effects;
pub mod files;
pub mod history;
pub mod invitations;
pub mod operations;
pub mod operator;
pub mod results;
pub mod typing;
pub mod views;
