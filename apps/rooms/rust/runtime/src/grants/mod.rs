//! Durable grant policy backed by one exclusively owned session document.
use crate::documents::{Completion, Document};
use rooms_application::documents::SessionDocument;
use rooms_application::documents::WriteFailure;
use rooms_application::grants::{
	ApplyError, Change, Command, Error, GrantLedger, GrantPolicy, GrantState, GrantStorage,
};

pub mod commands;
pub mod publications;

pub struct DurableGrants<D: Document> {
	file: D,
	ledger: GrantState,
	loaded: bool,
}

#[derive(Debug)]
pub enum LoadError<E> {
	Storage(E),
	Write(WriteFailure<E>),
	Policy(Error),
	Missing,
	Pending,
	Role,
}

impl<D: Document> DurableGrants<D> {
	pub fn new(file: D) -> Self {
		Self {
			file,
			ledger: GrantState::default(),
			loaded: false,
		}
	}
	/// Access is disabled until load completes, and after an interrupted or
	/// uncertain policy write. No mutable ledger escapes this persistence owner.
	pub fn ledger(&self) -> Result<core::cell::Ref<'_, GrantLedger>, Error> {
		self.ledger.ledger()
	}
	pub fn policy(&self, id: &str) -> Result<GrantPolicy, Error> {
		self.ledger.policy(id)
	}
	/// Observe the actual result of a cancelled operation before reloading.
	/// Keeping this separate from load ensures a failed abandoned write remains
	/// visible to the application rather than being swallowed by recovery.
	pub async fn finish_pending(&mut self) -> Option<Completion<D::Error>> {
		self.file.finish_pending().await
	}
	pub async fn load(&mut self) -> Result<(), LoadError<D::Error>> {
		if self.file.document() != SessionDocument::Grants {
			return Err(LoadError::Role);
		}
		if self.file.has_pending() {
			return Err(LoadError::Pending);
		}
		self.ledger.clear().map_err(LoadError::Policy)?;
		let ledger = match self.file.read().await.map_err(LoadError::Storage)? {
			Some(bytes) => GrantLedger::restore(&bytes).map_err(LoadError::Policy)?,
			None if self.loaded => return Err(LoadError::Missing),
			None => {
				let ledger = GrantLedger::default();
				self.file
					.replace(ledger.document().map_err(LoadError::Policy)?)
					.await
					.map_err(LoadError::Write)?;
				ledger
			}
		};
		self.ledger.install(ledger).map_err(LoadError::Policy)?;
		self.loaded = true;
		Ok(())
	}
	pub async fn apply(&mut self, command: Command) -> Result<Change, ApplyError<D::Error>> {
		let prepared = self.ledger.prepare(command).map_err(ApplyError::Policy)?;
		let written = prepared.persist(&mut GrantWriter(&mut self.file)).await?;
		self.ledger.commit(written).map_err(ApplyError::Policy)
	}
}

struct GrantWriter<'a, D>(&'a mut D);
impl<D: Document> GrantStorage for GrantWriter<'_, D> {
	type Error = D::Error;
	async fn replace(&mut self, bytes: Vec<u8>) -> Result<(), WriteFailure<Self::Error>> {
		self.0.replace(bytes).await
	}
}

impl<E: core::fmt::Display> core::fmt::Display for LoadError<E> {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		match self {
			Self::Storage(e) => e.fmt(f),
			Self::Policy(e) => e.fmt(f),
			Self::Write(WriteFailure::Unchanged(e)) => write!(f, "grant initialization did not commit: {e}"),
			Self::Write(WriteFailure::Indeterminate(e)) => write!(f, "grant initialization needs recovery: {e}"),
			Self::Pending => f.write_str("grant document has an unobserved operation"),
			Self::Role => f.write_str("grant owner requires a grant document"),
			Self::Missing => f.write_str("the previously loaded grant document is missing"),
		}
	}
}
impl<E: core::error::Error> core::error::Error for LoadError<E> {}
