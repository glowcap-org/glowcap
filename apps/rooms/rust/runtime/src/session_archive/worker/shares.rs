//! Durable-share routing and local publication reconciliation.
use super::*;

impl<B: Backend, P: Platform> Worker<B, P> {
	pub(super) async fn issued_shares(&mut self) -> Result<Vec<rooms_glowcap::client::archive::ShareView>, String> {
		match &self.targets.selected {
			Selection::Peer(peer) => return peer.archive.shares().await.map_err(|e| e.to_string()),
			Selection::Unavailable(why) => return Err(why.clone()),
			Selection::Local => {}
		}
		if !self.backend.durable_shares() {
			return Ok(Vec::new());
		}
		let specs = self.backend.active_shares().await?;
		if specs.is_empty() {
			return Ok(Vec::new());
		}
		let Some(issuer) = self.issuer.as_mut() else {
			return Err("this Rooms session has not published lookup names for its issued archive shares".into());
		};
		issuer.reconcile(specs.clone(), &self.state)?;
		issuer.listing(&specs)
	}

	pub(super) async fn issue_share(
		&mut self,
		share: rooms_application::archive::shares::Share,
	) -> Result<String, String> {
		match &self.targets.selected {
			Selection::Peer(peer) => return peer.archive.share(&share).await.map_err(|e| e.to_string()),
			Selection::Unavailable(why) => return Err(why.clone()),
			Selection::Local => {}
		}
		self.issue_local(share).await
	}

	async fn issue_local(&mut self, share: rooms_application::archive::shares::Share) -> Result<String, String> {
		if self.issuer.is_none() || !self.backend.durable_shares() {
			return Err("a selected archive peer is required to issue a durable share".into());
		}
		self.backend
			.change_share(rooms_application::archive::shares::Command::Issue(share.clone()))
			.await?;
		match self.issuer.as_mut().expect("issuer present").issue(&share, &self.state) {
			Ok(link) => Ok(link),
			Err(error) => {
				let _ = self
					.backend
					.change_share(rooms_application::archive::shares::Command::Revoke(share.id().into()))
					.await;
				Err(error)
			}
		}
	}

	pub(super) async fn revoke_share(&mut self, id: String) -> Result<bool, String> {
		match &self.targets.selected {
			Selection::Peer(peer) => return peer.archive.revoke_share(&id).await.map_err(|e| e.to_string()),
			Selection::Unavailable(why) => return Err(why.clone()),
			Selection::Local => {}
		}
		if self.issuer.is_none() || !self.backend.durable_shares() {
			return Err("a selected archive peer is required to revoke a durable share".into());
		}
		self.backend
			.change_share(rooms_application::archive::shares::Command::Revoke(id.clone()))
			.await?;
		self.issuer.as_mut().expect("issuer present").revoke(&id)
	}

	pub(super) async fn restore_issued(&mut self) -> Result<(), String> {
		if self.issuer.is_none() || !self.backend.durable_shares() {
			return Ok(());
		}
		if !matches!(self.targets.selected, Selection::Local) {
			return Ok(());
		}
		let specs = self.backend.active_shares().await?;
		self.issuer
			.as_mut()
			.expect("issuer present")
			.reconcile(specs, &self.state)
	}
}
