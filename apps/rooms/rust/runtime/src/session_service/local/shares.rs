use super::*;
use crate::session_service::verbs::archive_shares;
use rooms_application::archive::ShareKind;

impl<P: Platform> Local<P> {
	pub fn issued_archive_shares(&self) -> Result<Completion<Vec<rooms_glowcap::client::archive::ShareView>>, Error> {
		let facet = self.facet()?;
		archive_shares::prepare_list(&facet).start(&facet)
	}
	pub fn revoke_archive_share(&self, id: String) -> Result<Completion<bool>, Error> {
		let facet = self.facet()?;
		archive_shares::prepare_revoke(&facet, id).start(&facet)
	}
	pub fn drop_archive_share(&self, id: &str) -> Result<(), Error> {
		self.facet()?.0.shares.drop_share(id);
		Ok(())
	}
	pub fn read_archive_share(&self, id: &str, after: u64) -> Result<Completion<archive_shares::SharedPage>, Error> {
		let facet = self.facet()?;
		archive_shares::prepare_read(&facet, id, after)?.start(&facet)
	}
	pub fn share_archive(
		&self,
		kind: ShareKind,
		conversation: &str,
		peer: Option<&str>,
		durable: bool,
	) -> Result<Completion<()>, Error> {
		let facet = self.facet()?;
		archive_shares::prepare_offer(&facet, kind, conversation, peer.unwrap_or(""), durable)?.start(&facet)
	}
}
