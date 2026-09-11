//! A validated room-manager link. Temporary imported occurrences are released
//! by the binding's GC guards on success, refusal, timeout and cancellation.
use super::*;
use crate::routes::CheckpointRoutes;
use rooms_application::{room::policy::RoomPolicy, session::checkpoint::commands::CommandRoutes};

pub struct Manager<'a, D> {
	client: &'a Client<D>,
	link: String,
}
pub struct PolicyUpdate {
	pub name: String,
	pub policy: RoomPolicy,
}
pub struct StewardGrant {
	pub room_link: String,
	pub room_identity: String,
	pub steward_link: String,
}
impl<'a, D: Deadline> Manager<'a, D> {
	pub async fn take(client: &'a Client<D>, room: &Ref, link: &str) -> Result<Self, Error> {
		let candidate = client.enliven(link).await?;
		let governed = client
			.ask(
				&candidate,
				authority::GOVERNS,
				&[],
				"the room manager did not identify its room",
			)
			.await?;
		let identity = client
			.ask(
				room,
				authority::MANAGED_IDENTITY,
				&[],
				"the room did not identify its manager",
			)
			.await?;
		authority::verify_manager(&governed, &identity)?;
		Ok(Self {
			client,
			link: link.into(),
		})
	}
	pub fn sturdyref(&self) -> &str {
		&self.link
	}
	async fn call(&self, verb: &'static str, args: &[&str]) -> Result<Reply, Error> {
		let candidate = self.client.enliven(&self.link).await?;
		self.client
			.ask(&candidate, verb, args, "the room manager did not answer")
			.await
	}
	pub async fn room_link(&self) -> Result<String, Error> {
		let reply = self.call(authority::LINK, &[]).await?;
		Ok(authority::room_link(&reply)?.into())
	}
	pub async fn give_steward(&self) -> Result<StewardGrant, Error> {
		let reply = self.call(authority::GIVE_STEWARD, &[]).await?;
		let grant = authority::steward_grant(&reply)?;
		let token = CheckpointRoutes
			.authority_token(grant.room_link)
			.ok_or(Refusal::Token)?;
		grant.verify(&token)?;
		Ok(StewardGrant {
			room_link: grant.room_link.into(),
			room_identity: grant.room_identity.into(),
			steward_link: grant.steward_link.into(),
		})
	}
	pub async fn revoke_steward(&self, token: &str) -> Result<(), Error> {
		self.call(authority::REVOKE_STEWARD, &[token]).await?;
		Ok(())
	}
	pub async fn revoke_room_link(&self, token: &str) -> Result<(), Error> {
		self.call(authority::REVOKE_ROOM_LINK, &[token]).await?;
		Ok(())
	}
	pub async fn unregister(&self) -> Result<PolicyUpdate, Error> {
		let token = CheckpointRoutes.authority_token(&self.link).ok_or(Refusal::Token)?;
		let reply = self.call(authority::UNREGISTER_ROOM, &[&token]).await?;
		Self::policy(reply)
	}
	pub async fn set_policy(&self, policy: RoomPolicy, name: &str) -> Result<PolicyUpdate, Error> {
		let token = CheckpointRoutes.authority_token(&self.link).ok_or(Refusal::Token)?;
		let [visibility, entry, speaking] = policy.modes();
		let reply = self
			.call(authority::SET_POLICY, &[&token, visibility, entry, speaking, name])
			.await?;
		Self::policy(reply)
	}
	fn policy(reply: Reply) -> Result<PolicyUpdate, Error> {
		let update = authority::policy_update(&reply)?;
		Ok(PolicyUpdate {
			name: update.name.into(),
			policy: update.policy,
		})
	}
}
