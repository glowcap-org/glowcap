//! Share documents share the archive's directory lease and serial disk worker.
use super::*;
use rooms_application::archive::shares::{self, ApplyError, Change, Command, Ledger, Share};
impl FileArchive {
	pub async fn change_share(&mut self, command: Command) -> Result<Change, String> {
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
	pub async fn active_shares(&mut self) -> Result<Vec<Share>, String> {
		match self
			.submit(|store| {
				store
					.shares
					.records()
					.map(|rows| Completion::Shares(rows.filter(|s| !s.revoked()).cloned().collect()))
					.map_err(|e| e.to_string())
			})
			.await?
		{
			Completion::Shares(shares) => Ok(shares),
			_ => unreachable!("share listing completion"),
		}
	}
}
impl Store {
	pub(super) fn open_shares(&mut self) -> Result<(), String> {
		self.shares = match storage::read(&self.directory.path.join(shares::FILE), shares::MAX_DOCUMENT_BYTES)
			.map_err(|e| e.to_string())?
		{
			Some(bytes) => Ledger::restore(&bytes).map_err(|e| e.to_string())?,
			None => {
				let ledger = Ledger::default();
				let bytes = ledger.document().map_err(|e| e.to_string())?;
				let written = storage::atomic::replace(&self.directory, shares::FILE, [bytes.as_slice()]);
				self.written(written)?;
				ledger
			}
		};
		Ok(())
	}
	fn change_share(&mut self, command: Command) -> Result<Change, String> {
		let result = self.shares.apply(command, |bytes| {
			storage::atomic::replace(&self.directory, shares::FILE, [bytes])
		});
		match result {
			Ok(change) => Ok(change),
			Err(ApplyError::Policy(error)) => Err(error.to_string()),
			Err(ApplyError::Storage(failure)) => self.written(Err(failure)).map(|()| unreachable!()),
		}
	}
}
