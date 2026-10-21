//! Durable-share routing and local publication reconciliation.
use super::*;

impl<B: Backend, P: Platform> Worker<B, P> {
	pub(super) async fn issue_share(
		&mut self,
		share: rooms_application::archive::shares::Share,
	) -> Result<String, Error> {
		match &self.targets.selected {
			Selection::Peer(peer) => return peer.archive.share(&share).await.map_err(Error::peer),
			Selection::Unavailable(_) => return Err(Error::closed("the selected archive peer is unavailable")),
			Selection::Local => {}
		}
		self.issue_local(share).await
	}

	async fn issue_local(&mut self, share: rooms_application::archive::shares::Share) -> Result<String, Error> {
		if self.issuer.is_none() || !self.backend.durable_shares() {
			return Err(Error::refused(
				"a selected archive peer is required to issue a durable share",
			));
		}
		self.backend
			.change_share(rooms_application::archive::shares::Command::Issue(share.clone()))
			.await?;
		let Some(issuer) = self.issuer.as_mut() else {
			return Err(Error::refused(
				"a selected archive peer is required to issue a durable share",
			));
		};
		match issuer.issue(&share, &self.state) {
			Ok(link) => Ok(link),
			Err(error) => {
				// A revoke that also fails is retained behind the publication failure.
				let revoked = self
					.backend
					.change_share(rooms_application::archive::shares::Command::Revoke(share.id().into()))
					.await
					.map(|_| ());
				Err(error.retain_result(revoked))
			}
		}
	}

	pub(super) async fn revoke_share(&mut self, id: String) -> Result<bool, Error> {
		match &self.targets.selected {
			Selection::Peer(peer) => return peer.archive.revoke_share(&id).await.map_err(Error::peer),
			Selection::Unavailable(_) => return Err(Error::closed("the selected archive peer is unavailable")),
			Selection::Local => {}
		}
		if self.issuer.is_none() || !self.backend.durable_shares() {
			return Err(Error::refused(
				"a selected archive peer is required to revoke a durable share",
			));
		}
		self.backend
			.change_share(rooms_application::archive::shares::Command::Revoke(id.clone()))
			.await?;
		let Some(issuer) = self.issuer.as_mut() else {
			return Err(Error::refused(
				"a selected archive peer is required to revoke a durable share",
			));
		};
		issuer.revoke(&id)
	}

	pub(super) async fn restore_issued(&mut self) -> Result<(), Error> {
		if self.issuer.is_none() || !self.backend.durable_shares() {
			return Ok(());
		}
		if !matches!(self.targets.selected, Selection::Local) {
			return Ok(());
		}
		let specs = self.backend.active_shares().await?;
		let Some(issuer) = self.issuer.as_mut() else {
			return Ok(());
		};
		issuer.reconcile(specs, &self.state)
	}
}
