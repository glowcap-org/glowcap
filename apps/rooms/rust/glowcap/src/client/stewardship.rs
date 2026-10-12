//! Live moderator custody. No state borrow survives an external call. One
//! core-owned acquisition ticket prevents concurrent replacement and late revival.
use super::{
	manager::{Manager, PolicyUpdate},
	*,
};
use crate::routes::CheckpointRoutes;
use rooms_application::{
	failure::{Failure, FailureCode},
	room::{
		policy::RoomPolicy,
		stewardship::{self as custody, Acquisition, Attempt, Kind, Publication},
	},
	session::checkpoint::commands::CommandRoutes,
};
use std::cell::RefCell;

pub struct Links {
	pub room: Option<String>,
	pub steward: Option<String>,
	pub manager: Option<String>,
}
pub struct Stewardship<D> {
	client: Client<D>,
	room: Ref,
	state: RefCell<custody::Stewardship<Ref>>,
}
fn publication(link: String) -> Result<Publication, Error> {
	let token = CheckpointRoutes.authority_token(&link).ok_or(Refusal::Token)?;
	Ok(Publication::new(link, token)?)
}
impl<D: Deadline> Stewardship<D> {
	pub fn new(client: Client<D>, room: Ref) -> Self {
		Self {
			client,
			room,
			state: RefCell::new(Default::default()),
		}
	}
	pub fn held(&self) -> bool {
		self.state.borrow().held()
	}
	pub fn links(&self) -> Links {
		let state = self.state.borrow();
		let link = |p: Option<&Publication>| p.map(|p| p.link().to_owned());
		Links {
			room: link(state.room()),
			steward: link(state.steward()),
			manager: link(state.manager()),
		}
	}
	/// Compare custody without copying the three bearer links into a snapshot.
	pub fn retains(&self, kind: Kind, link: &str) -> bool {
		let state = self.state.borrow();
		match kind {
			Kind::Room => state.room(),
			Kind::Manager => state.manager(),
			Kind::Steward => state.steward(),
		}
		.is_some_and(|held| held.link() == link)
	}
	fn begin(&self) -> Result<Attempt, Error> {
		Ok(self.state.borrow_mut().begin()?)
	}
	fn manager_link(&self) -> Result<String, Error> {
		self.state
			.borrow()
			.manager()
			.map(|p| p.link().to_owned())
			.ok_or(custody::Error::NoManager.into())
	}
	async fn manager(&self) -> Result<Manager<'_, D>, Error> {
		Manager::take(&self.client, &self.room, &self.manager_link()?).await
	}
	async fn room_publication(&self) -> Result<Publication, Error> {
		let reply = self
			.client
			.ask(
				&self.room,
				authority::LINK,
				&[],
				"the room did not answer linking itself",
			)
			.await?;
		publication(authority::room_link(&reply)?.into())
	}
	pub async fn link(&self) -> Result<String, Error> {
		let attempt = self.begin()?;
		let manager = self.state.borrow().manager().map(|p| p.link().to_owned());
		let room = if let Some(link) = manager {
			let manager = Manager::take(&self.client, &self.room, &link).await?;
			attempt.check()?;
			publication(manager.room_link().await?)?
		} else {
			self.room_publication().await?
		};
		let link = room.link().to_owned();
		self.state.borrow_mut().accept(attempt, Acquisition::Room(room))?;
		Ok(link)
	}
	pub async fn take_manager(&self, link: &str) -> Result<(), Error> {
		let attempt = self.begin()?;
		let manager = publication(link.into())?;
		Manager::take(&self.client, &self.room, manager.link()).await?;
		self.state.borrow_mut().accept(attempt, Acquisition::Manager(manager))?;
		Ok(())
	}
	pub async fn claim(&self) -> Result<bool, Error> {
		if self.held() {
			return Ok(true);
		}
		if self.state.borrow().manager().is_none() {
			return Ok(false);
		}
		let attempt = self.begin()?;
		let result = async {
			let manager = self.manager().await?;
			attempt.check()?;
			let grant = manager.give_steward().await?;
			attempt.check()?;
			let room = publication(grant.room_link)?;
			let steward = publication(grant.steward_link)?;
			let reference = self.client.enliven(steward.link()).await?;
			self.state.borrow_mut().accept(
				attempt,
				Acquisition::Steward {
					room,
					publication: steward,
					reference,
				},
			)?;
			Ok::<_, Error>(true)
		}
		.await;
		match result {
			Err(Error::Binding(ref error))
				if error.kind() == glowcap::ErrorKind::Broken
					&& error
						.message()
						.and_then(Failure::parse)
						.is_some_and(|f| f.code == FailureCode::NotSteward) =>
			{
				Ok(false)
			}
			other => other,
		}
	}
	pub async fn take(&self, link: &str) -> Result<(), Error> {
		{
			let state = self.state.borrow();
			if state.held() && state.steward().is_some_and(|p| p.link() == link) {
				return Ok(());
			}
		}
		let attempt = self.begin()?;
		let steward = publication(link.into())?;
		let room = self.room_publication().await?;
		attempt.check()?;
		let candidate = self.client.enliven(link).await.map_err(|error| match error {
			Error::Binding(ref cause) if cause.is_publication_not_found() => custody::Error::StewardRetired.into(),
			other => other,
		})?;
		attempt.check()?;
		let governs = self
			.client
			.ask(
				&candidate,
				authority::GOVERNS,
				&[],
				"the moderator capability did not identify its room",
			)
			.await?;
		authority::verify_steward(&governs, room.token())?;
		self.state.borrow_mut().accept(
			attempt,
			Acquisition::Steward {
				room,
				publication: steward,
				reference: candidate,
			},
		)?;
		Ok(())
	}
	pub fn forget(&self, kind: Kind, token: &str) {
		self.state.borrow_mut().forget(kind, token);
	}
	pub fn drop_steward(&self) {
		self.state.borrow_mut().drop_steward();
	}
	pub fn drop_manager(&self) {
		self.state.borrow_mut().drop_manager();
	}
	pub fn release(&self) {
		self.state.borrow_mut().release();
	}
	pub async fn revoke_room_link(&self, token: &str) -> Result<(), Error> {
		self.manager().await?.revoke_room_link(token).await
	}
	pub async fn revoke_steward(&self, token: &str) -> Result<(), Error> {
		self.manager().await?.revoke_steward(token).await
	}
	pub async fn unregister(&self) -> Result<PolicyUpdate, Error> {
		self.manager().await?.unregister().await
	}
	pub async fn set_policy(&self, policy: RoomPolicy, name: &str) -> Result<PolicyUpdate, Error> {
		self.manager().await?.set_policy(policy, name).await
	}
	pub async fn kick(&self, nick: &str) -> Result<(), Error> {
		let reference = self.state.borrow().reference()?.clone();
		self.client
			.ask(
				&reference,
				authority::KICK,
				&[nick],
				"the steward did not answer the kick",
			)
			.await?;
		Ok(())
	}
}
