use super::*;
use rooms_application::grants::{Rights, protocol};

/// A connection-scoped facet and the authority to revoke it. Dropping this
/// handle releases local custody; only an acknowledged revoke or connection
/// retirement revokes copies already passed to another holder.
pub struct Facet<D> {
	pub session: Session<D>,
	revoker: Ref,
}
impl<D: Deadline> Facet<D> {
	pub async fn revoke(&self) -> Result<(), Error> {
		self.session
			.client
			.call(&self.revoker, verbs::REVOKE, &[], "the Rooms facet was not revoked")
			.await?;
		Ok(())
	}
}
impl<D: Deadline + Clone> Session<D> {
	pub async fn facet(&self, rights: Rights) -> Result<Facet<D>, Error> {
		let reply = self.call(verbs::FACET, &[right(rights).into()]).await?;
		let Some([Argument::Reference(facet), Argument::Reference(revoker)]) = reply.as_list() else {
			return Err(Error::Reply("Rooms session returned no facet and revoker"));
		};
		Ok(Facet {
			session: Session::new(self.client.clone(), facet.clone()),
			revoker: revoker.clone(),
		})
	}
}

pub struct GrantPatch<'a> {
	pub rights: Option<Rights>,
	pub history: Option<bool>,
	pub suspended: Option<bool>,
	pub note: Option<&'a str>,
}
impl<D: Deadline> Session<D> {
	pub async fn issue_grant(
		&self,
		id: &str,
		rights: Rights,
		label: &str,
		history: bool,
	) -> Result<protocol::GrantView, Error> {
		let reply = self
			.call(
				protocol::ISSUE,
				&[id.into(), right(rights).into(), label.into(), history.into()],
			)
			.await?;
		grant(&reply)
	}
	pub async fn revoke_grant(&self, id: &str) -> Result<(), Error> {
		self.call(protocol::REVOKE, &[id.into()]).await?;
		Ok(())
	}
	pub async fn set_grant_policy(&self, id: &str, patch: GrantPatch<'_>) -> Result<protocol::GrantView, Error> {
		let reply = self
			.call(
				protocol::SET_POLICY,
				&[
					id.into(),
					patch.rights.map(right).map(Argument::from).unwrap_or(Argument::Void),
					patch.history.map(Argument::from).unwrap_or(Argument::Void),
					patch.suspended.map(Argument::from).unwrap_or(Argument::Void),
					patch.note.map(Argument::from).unwrap_or(Argument::Void),
				],
			)
			.await?;
		grant(&reply)
	}
}
fn right(rights: Rights) -> &'static str {
	match rights {
		Rights::Observe => "observe",
		Rights::Interact => "interact",
		Rights::Admin => "admin",
	}
}
fn grant(reply: &Argument) -> Result<protocol::GrantView, Error> {
	protocol::GrantView::decode(
		reply
			.as_str()
			.ok_or(Error::Reply("Rooms session returned no grant view"))?,
	)
	.map_err(Error::Grant)
}
