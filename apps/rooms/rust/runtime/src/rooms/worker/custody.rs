//! Checkpoint authority changes retain the membership and its posted lines.
use super::*;

impl<P: Platform> RoomWorker<P> {
	pub(super) async fn retired_authority(
		&self,
		before: &intent::Intent,
		kind: Kind,
		token: String,
	) -> Result<(), Error> {
		let kind = match kind {
			Kind::Room => Authority::Room,
			Kind::Manager => Authority::Manager,
			Kind::Steward => Authority::Steward,
		};
		let conversation = Id::new(before.id.clone().into())
			.ok_or_else(|| Error::invalid("room conversation id exceeds its field"))?;
		let token =
			FactText::new(token.into()).ok_or_else(|| Error::invalid("room authority token exceeds its field"))?;
		let scope = crate::session::commands::FactScope::new();
		let expected = self
			.commit_observation(before, &scope, |context| {
				Ok(Fact::RoomAuthority {
					context,
					conversation,
					kind,
					token,
					claimable: false,
				})
			})
			.await?;
		if let Some(expected) = expected
			&& let Some(live) = self.shared.borrow_mut().rooms.get_mut(&before.id)
		{
			live.intent = expected;
		}
		Ok(())
	}
	pub(super) async fn reconcile_custody(&mut self, wanted: &Wanted) -> Result<(), Error> {
		let room = {
			let mut state = self.shared.borrow_mut();
			let Some(live) = state.rooms.get_mut(&wanted.intent.id) else {
				return Ok(());
			};
			if live.intent == wanted.intent {
				return Ok(());
			}
			// Forget only authority removed by this checkpoint transition. A result
			// command may already be acquiring its replacement on the same seat.
			let custody = live.room.stewardship();
			if live.intent.manager != wanted.intent.manager
				&& let Some(link) = &live.intent.manager
				&& custody.retains(Kind::Manager, link)
			{
				custody.drop_manager();
			}
			if live.intent.steward != wanted.intent.steward
				&& let Some(link) = &live.intent.steward
				&& custody.retains(Kind::Steward, link)
			{
				custody.drop_steward();
			}
			live.room.clone()
		};
		let acquire = async {
			let custody = room.stewardship();
			if let Some(link) = wanted.intent.manager.as_deref()
				&& !custody.retains(Kind::Manager, link)
			{
				custody
					.take_manager(link)
					.await
					.map_err(|error| join::Failure::authority(Kind::Manager, link, error))?;
			}
			if let Some(link) = wanted.intent.steward.as_deref()
				&& !custody.retains(Kind::Steward, link)
			{
				custody
					.take(link)
					.await
					.map_err(|error| join::Failure::authority(Kind::Steward, link, error))?;
			}
			Ok::<_, join::Failure>(())
		};
		tokio::pin!(acquire);
		let mut changes = self.directories.changes();
		changes.mark_unchanged();
		loop {
			if *self.stopping.borrow() {
				return Ok(());
			}
			if self
				.wanted()?
				.get(&wanted.intent.id)
				.is_none_or(|now| now.intent != wanted.intent)
			{
				self.schedule_retry();
				return Ok(());
			}
			tokio::select! {
				result = &mut acquire => {
					match result {
						Ok(()) => {
							let mut state = self.shared.borrow_mut();
							if let Some(live) = state.rooms.get_mut(&wanted.intent.id) {
								live.intent = wanted.intent.clone();
							}
							state.issues.remove(&wanted.intent.subject);
						}
						Err(error) => {
							let reason = error.to_string();
							if let join::Failure::Retired {kind, token} = error {
								self.retired_authority(&wanted.intent, kind, token).await?;
							}
							self.shared.borrow_mut().issues.insert(wanted.intent.subject.clone(), reason);
							self.schedule_retry();
						}
					}
					return Ok(());
				}
				_ = changes.changed() => {},
				_ = self.stopping.changed() => return Ok(()),
			}
		}
	}
}
