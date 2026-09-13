//! Share documents share the archive's directory lease and serial disk worker.
use super::*;
use rooms_application::archive::shares::{self, ApplyError, Change, Command, Ledger, Share};
impl FileArchive {
	pub async fn change_share(&mut self, command: Command) -> Result<Change, Error> {
		match self
			.submit(move |store| store.change_share(command).map(Completion::ShareChange))
			.await?
		{
			Completion::ShareChange(change) => Ok(change),
			_ => unreachable!("share mutation completion"),
		}
	}
	/// Publication code receives committed active specifications only. This list
	/// does not confer issuer authority or publish capabilities by itself.
	pub async fn active_shares(&mut self) -> Result<Vec<Share>, Error> {
		match self
			.submit(|store| {
				store
					.shares
					.records()
					.map(|rows| Completion::Shares(rows.filter(|s| !s.revoked()).cloned().collect()))
					.map_err(share_policy)
			})
			.await?
		{
			Completion::Shares(shares) => Ok(shares),
			_ => unreachable!("share listing completion"),
		}
	}
}
impl Store {
	pub(super) fn open_shares(&mut self) -> Result<(), DiskFailure> {
		self.shares = match storage::read(&self.directory.path().join(shares::FILE), shares::MAX_DOCUMENT_BYTES)? {
			Some(bytes) => Ledger::restore(&bytes).map_err(share_policy)?,
			None => {
				let ledger = Ledger::default();
				let bytes = ledger.document().map_err(share_policy)?;
				let written = storage::atomic::replace(&self.directory, shares::FILE, [bytes.as_slice()]);
				self.written(written)?;
				ledger
			}
		};
		Ok(())
	}
	fn change_share(&mut self, command: Command) -> Result<Change, DiskFailure> {
		let result = self.shares.apply(command, |bytes| {
			storage::atomic::replace(&self.directory, shares::FILE, [bytes])
		});
		match result {
			Ok(change) => Ok(change),
			Err(ApplyError::Policy(error)) => Err(share_policy(error)),
			Err(ApplyError::Storage(failure)) => self.written(Err(failure)).map(|()| unreachable!()),
		}
	}
}

/// The share ledger's own verdict on a command or a stored document. It is a
/// policy answer, never the disk's, so it stays a refusal the caller cannot
/// retry into success.
fn share_policy(error: shares::Error) -> DiskFailure {
	DiskFailure::Invalid(error.to_string().into())
}
