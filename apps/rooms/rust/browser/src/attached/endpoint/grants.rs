use super::*;
use rooms_application::grants::{protocol::GrantView, Command, PolicyPatch, Rights};
use rooms_glowcap::client::session::GrantPatch;
impl Endpoint {
	pub async fn issue_grant(&self, id: &str, rights: Rights, label: &str, history: bool) -> Result<GrantView> {
		match self {
			Self::Remote(s) => s.issue_grant(id, rights, label, history).await.map_err(error),
			Self::Local(s, _) => s
				.grant(Command::Issue {
					id: id.into(),
					rights,
					label: label.into(),
					history,
				})
				.map_err(error)?
				.wait()
				.await?
				.ok_or_else(|| "Rooms grant issue returned no view".into()),
		}
	}
	pub async fn revoke_grant(&self, id: &str) -> Result<()> {
		match self {
			Self::Remote(s) => s.revoke_grant(id).await.map_err(error),
			Self::Local(s, _) => s
				.grant(Command::Revoke { id: id.into() })
				.map_err(error)?
				.wait()
				.await
				.map(|_| ()),
		}
	}
	pub async fn set_grant_policy(&self, id: &str, patch: GrantPatch<'_>) -> Result<GrantView> {
		match self {
			Self::Remote(s) => s.set_grant_policy(id, patch).await.map_err(error),
			Self::Local(s, _) => s
				.grant(Command::SetPolicy {
					id: id.into(),
					patch: PolicyPatch {
						rights: patch.rights,
						history: patch.history,
						suspended: patch.suspended,
						note: patch.note.map(Into::into),
					},
				})
				.map_err(error)?
				.wait()
				.await?
				.ok_or_else(|| "Rooms grant change returned no view".into()),
		}
	}
}
