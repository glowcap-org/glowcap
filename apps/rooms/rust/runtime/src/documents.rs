//! Exclusive document effects and custody across cancelled observations.
use rooms_application::{documents::WriteFailure, session::state::SessionStorage};
use std::future::Future;
pub mod volatile;
pub use volatile::{VolatileDocument, VolatileDocuments};

#[derive(Debug)]
#[must_use = "a retired operation's result must be observed"]
pub enum Completion<E> {
	Read(Result<Option<Vec<u8>>, E>),
	Write(Result<(), WriteFailure<E>>),
}

pub struct Stored {
	pub checkpoint: Option<Vec<u8>>,
	pub effects: Option<Vec<u8>>,
}

/// One exclusive pair of durable documents. Dropping an I/O observation must
/// not cancel admitted work or release its storage lease. A later read must
/// refuse while either document has pending work. `finish_pending` observes each
/// completion, including an indeterminate write, before recovery can reload.
/// Implementations validate document roles and bound reads before allocation.
pub trait Documents: SessionStorage<Error: std::error::Error + 'static> {
	fn has_pending(&self) -> bool;
	fn read(&mut self) -> impl Future<Output = Result<Stored, Self::Error>>;
	fn finish_pending(&mut self) -> impl Future<Output = [Option<Completion<Self::Error>>; 2]>;
}

/// One exclusive document with a fixed role. Read bounds apply before allocation.
/// Replacement validates the role's encoding and byte ceiling before admission.
/// Dropping an observer must retain admitted work and its storage lease until
/// finish_pending observes the actual outcome. Read and replace refuse while an
/// earlier observation remains pending. Implementations need not suspend.
pub trait Document {
	type Error: std::error::Error + 'static;
	fn document(&self) -> rooms_application::documents::SessionDocument;
	fn has_pending(&self) -> bool;
	fn read(&mut self) -> impl Future<Output = Result<Option<Vec<u8>>, Self::Error>>;
	fn replace(&mut self, bytes: Vec<u8>) -> impl Future<Output = Result<(), WriteFailure<Self::Error>>>;
	fn finish_pending(&mut self) -> impl Future<Output = Option<Completion<Self::Error>>>;
}
