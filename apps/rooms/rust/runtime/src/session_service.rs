//! Session capability dispatch and attached views, shared above platform effects.
mod answer;
mod local;
mod revision;
pub use local::{Local, Observation as LocalObservation, Observer as LocalObserver};
pub use revision::Completion;
mod authority;
pub mod error;
pub mod events;
pub mod facet;
mod history_changes;
pub mod notice;
mod snapshot;
pub mod verbs;
pub use verbs::attachments::ArchivedFile;
mod views;
use crate::session_commands::SessionCommands;
use std::rc::Rc;
pub type Stop = tokio::sync::watch::Receiver<bool>;
/// Visualization transport/lifetime supplied by the embedding application.
/// Its existing credential and view contract remains visible on both targets.
pub trait Visualization {
	fn on_invalidated(&self, notify: Rc<dyn Fn(&str)>);
	fn kick(&self);
	fn stop(&self);
	fn close(&self) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<(), error::Error>> + '_>>;
	fn changes(&self) -> tokio::sync::watch::Receiver<()>;
	fn snapshot(&self, scope: &str, commands: &SessionCommands) -> Result<glowcap::Argument, error::Error>;
	fn reconcile(&self, commands: &SessionCommands);
}

pub trait Platform: crate::platform::Platform + crate::direct_publications::Platform {}
impl<T: crate::platform::Platform + crate::direct_publications::Platform> Platform for T {}

pub mod directs;

pub mod viz;
mod workers;
pub use workers::Worker;
mod observed;
mod open_error;
mod owners;
pub use open_error::OpenError;
mod session;
pub use session::{Inputs, Session};
