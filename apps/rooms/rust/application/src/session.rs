//! Shared-session application owners. Adapters drive their delivery effects.
pub mod checkpoint;
pub mod command;
pub mod diagnosis;
pub mod directory;
pub mod effect;
pub mod event;
pub mod operations;
pub mod operator;
pub mod room_view;
pub mod subject;
pub mod visualizer;

pub const CHANGED: &str = "changed";
pub const EVENT: &str = "event";
pub const OPERATIONS_CHANGED: &str = "operationsChanged";
pub const HISTORY_CHANGED: &str = "historyChanged";

pub(crate) mod fields;
pub mod snapshot;
pub mod verbs;

pub mod state;
